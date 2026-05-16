-- xmake.lua for L-SMASH
-- Cross-platform build with xmake (coexists with configure/make)
--
-- Quick start:
--   xmake f -m release               configure release build (shared library by default)
--   xmake                            build library + CLI tools
--   xmake build lsmash               build library only
--   xmake f -m release --lsmash_kind=static  build as static library instead
--   xmake f -m debug                 debug build with -g -O0
--   xmake install -o /usr/local      install
--   xmake clean                      clean build artifacts

set_project("lsmash")
set_version("2.20.0")
set_description("ISOBMFF (MP4) muxer/demuxer library")

add_rules("mode.debug", "mode.release")

-- Library kind: shared (default) or static
-- Named "lsmash_kind" to avoid collision with xmake's built-in "kind" config
option("lsmash_kind", {default = "shared", description = "Library kind",
                       values = {"shared", "static"}})

-- Generate config.h (needed by CLI tools for version display)
-- This mirrors what ./configure does: extract git revision/hash.
rule("gen_config_h")
    before_build(function (target)
        if not os.isfile("config.h") then
            local rev, hash = "0", ""
            if os.isdir(".git") then
                import("lib.detect.find_tool")
                local git = find_tool("git")
                if git then
                    local outdata, errdata = try { function () return os.iorunv(git.program, {"rev-list", "HEAD", "--count"}) end }
                    if outdata and #outdata > 0 then
                        rev = tostring(outdata:trim())
                    end
                    outdata, errdata = try { function () return os.iorunv(git.program, {"describe", "--always"}) end }
                    if outdata and #outdata > 0 then
                        hash = tostring(outdata:trim())
                    end
                end
            end
            io.writefile("config.h", '#define LSMASH_REV "' .. rev .. '"\n#define LSMASH_GIT_HASH "' .. hash .. '"\n')
        end
    end)

-- Generate liblsmash.ver (version script for symbol export control).
-- Mirrors configure's logic: scan common/ and importer/ headers for
-- internal lsmash_* function declarations, hide them in local:, but keep
-- the ones needed by CLI tools exported.
rule("gen_ver")
    before_build(function (target)
        if os.isfile("liblsmash.ver") then return end
        -- Symbols CLI tools need (must stay in global: via lsmash_* wildcard)
        local cli_needed = {
            lsmash_win32_fopen = true,
            lsmash_string_from_wchar = true,
            lsmash_importer_open = true,
            lsmash_importer_close = true,
            lsmash_importer_get_access_unit = true,
            lsmash_importer_get_last_delta = true,
            lsmash_importer_construct_timeline = true,
            lsmash_importer_get_track_count = true,
            lsmash_duplicate_summary = true,
        }
        -- Known return-type prefixes that appear before internal lsmash_* functions.
        -- Same list as configure:402-403 (the grep pattern).
        local type_prefixes = {
            "void", "lsmash_bits_t", "uint64_t", "int", "int64_t",
            "lsmash_bs_t", "uint8_t", "uint16_t", "uint32_t",
            "lsmash_entry_list_t", "lsmash_entry_t",
            "lsmash_multiple_buffers_t", "double", "float", "FILE",
        }
        local internal = {}
        for _, dir in ipairs({"common", "importer"}) do
            for _, h in ipairs(os.files(path.join(dir, "*.h"))) do
                for line in io.lines(h) do
                    line = line:trim()
                    -- Skip comments, preprocessor lines, and non-declaration lines
                    if line:find("^//") or line:find("^%*") or line:find("^/[*]")
                        or line:find("^#") or line == "" then
                        -- skip
                    else
                        -- Look for: <type> [*] lsmash_<name>  ( ( may be on next line)
                        for _, tp in ipairs(type_prefixes) do
                            local func = line:match(tp .. "%s+%*?%s*(lsmash_[%w_]+)")
                            if func and not cli_needed[func] then
                                internal[func] = true
                                break
                            end
                        end
                    end
                end
            end
        end
        -- Build version script
        local lines = {"LSMASH_2 {"}
        table.insert(lines, "    global: lsmash_*;")
        table.insert(lines, "            ISOM_*;")
        table.insert(lines, "            QT_*;")
        table.insert(lines, "    local:  *;")
        for func, _ in pairs(internal) do
            table.insert(lines, "           " .. func .. ";")
        end
        table.insert(lines, "};")
        io.writefile("liblsmash.ver", table.concat(lines, "\n") .. "\n")
    end)

-- Generate lsmash.def for Windows DLL exports by running the built dllexportgen tool.
-- This reuses the existing windows/dllexportgen.cs code (no Lua reimplementation).
rule("gen_def")
    before_build(function (target)
        if not os.isfile("lsmash.def") then
            import("core.project.project")
            local gen = project.target("dllexportgen")
            if gen then
                local exe = gen:targetfile()
                os.runv(exe, {os.projectdir()})
            end
        end
    end)

-- dllexportgen: C# tool that parses lsmash.h and writes lsmash.def
-- Built only on Windows; mirrors the original windows/dllexportgen.csproj.
target("dllexportgen")
    set_kind("binary")
    set_languages("csharp")
    add_files("windows/dllexportgen.cs")
    set_default(false)

-- Main library
target("lsmash")
    set_kind("$(lsmash_kind)")
    add_rules("gen_config_h")
    -- On Linux shared, also generate version script to match configure symbol exports
    add_rules("gen_ver")
    add_files("common/*.c",
              "codecs/*.c",
              "core/*.c",
              "importer/*.c",
              "obuparse/obuparse.c")
    add_includedirs(".", "obuparse")
    -- Language standard: C99. xmake v3.0.8 erroneously adds -TP (C++ mode)
    -- to MSVC when set_languages("c99") is used, so we handle it in on_load.
    on_load(function (target)
        local toolchain = target:toolchain("gcc", "clang", "mingw")
        if toolchain then
            target:add("cflags", "-std=c99")
            target:add("cflags", "-Wshadow", "-Wall", "-pedantic", "-ffast-math")
        end
        if target:toolchain("msvc") then
            -- MSVC compiles .c as C by default, no flag needed.
            -- But we need to override xmake's -TP if it's somehow added.
            target:add("cflags", "/TC")
        end
        if target:is_plat("linux") and target:kind() == "shared" then
            target:add("cflags", "-fPIC")
            target:add("shflags", "-Wl,-soname,liblsmash.so.2")
            target:add("shflags", "-Wl,--version-script,liblsmash.ver")
        end
    end)
    -- After linking, create symlink so SONAME-based resolution finds the library
    after_link(function (target)
        if target:is_plat("linux") and target:kind() == "shared" then
            local dir = target:targetdir()
            local symlink = path.join(dir, "liblsmash.so.2")
            if not os.isfile(symlink) and not os.islink(symlink) then
                os.ln("liblsmash.so", symlink)
            end
        end
    end)
    -- Platform and toolchain specific settings
    on_load(function (target)
        if target:is_plat("windows") then
            -- Build dllexportgen first, then run it to generate lsmash.def
            if target:kind() == "shared" then
                target:add("deps", "dllexportgen")
                target:add("rules", "gen_def")
                target:add("files", "lsmash.def")
            end
            -- MinGW needs __USE_MINGW_ANSI_STDIO for correct printf format support
            local toolchain = target:toolchain("mingw", "gcc", "clang")
            if toolchain then
                target:add("defines", "__USE_MINGW_ANSI_STDIO=1")
            end
            target:add("syslinks", "ws2_32", "shell32")  -- Winsock + CommandLineToArgvW
        else
            target:add("syslinks", "m")
        end
    end)
    add_headerfiles("lsmash.h")
    if not is_mode("debug") then
        set_optimize("smallest")
    end

-- Shared CLI code (static lib linked into each tool)
target("cli_common")
    set_kind("static")
    set_default(false)
    add_files("cli/cli.c")
    add_includedirs(".")
    on_load(function (target)
        local toolchain = target:toolchain("gcc", "clang", "mingw")
        if toolchain then
            target:add("cflags", "-std=c99")
            target:add("cflags", "-Wshadow", "-Wall", "-pedantic", "-ffast-math")
        end
        if target:toolchain("msvc") then
            target:add("cflags", "/TC")
        end
        if target:is_plat("windows") then
            target:add("syslinks", "shell32")  -- CommandLineToArgvW
        end
    end)
    if not is_mode("debug") then
        set_optimize("smallest")
    end

-- CLI tools: muxer, remuxer, boxdumper, timelineeditor
for _, tool in ipairs({"muxer", "remuxer", "boxdumper", "timelineeditor"}) do
    target(tool)
        set_kind("binary")
        add_files("cli/" .. tool .. ".c")
        add_deps("lsmash", "cli_common")
        add_includedirs(".")
        on_load(function (target)
            local toolchain = target:toolchain("gcc", "clang", "mingw")
            if toolchain then
                target:add("cflags", "-std=c99")
                target:add("cflags", "-Wshadow", "-Wall", "-pedantic", "-ffast-math")
            end
            if target:toolchain("msvc") then
                target:add("cflags", "/TC")
            end
        end)
        if not is_mode("debug") then
            set_optimize("smallest")
        end
end
