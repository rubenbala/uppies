// Build metaprogram for Uppies.
//
//     jai build.jai                 debug build   -> bin/uppies.exe (bin/uppies on macOS and Linux)
//     jai build.jai - release       optimized build (no console window)
//     jai build.jai - run           build, then launch the app
//     jai build.jai - bundle        release build, then what a release ships, each
//                                   with a .sha256 beside it:
//                                   Windows: bin/Uppies-<version>-setup.exe (Inno Setup 6)
//                                   macOS:   bin/Uppies-<version>-mac.dmg (Uppies.app and
//                                            a link to drag it into Applications)
//                                   Linux:   bin/Uppies-<version>-linux-x86_64.tar.gz (the
//                                            executable, icons and install.sh)
//
// Shaders are compiled here, at build time, and their bytecode is embedded
// in the executable: no shader compiler ships with the app, startup never
// waits on compilation, and a shader error is a build error. The icon is
// embedded the same way, from assets/icon.png (Windows and Linux).
//
// Linux compiles the Vulkan shaders with glslc (apt install glslc), or
// glslangValidator if that is what is installed, and needs libX11's
// development files (apt install libx11-dev). Everything else the app uses
// (Vulkan, libcurl, OpenSSL, libsecret, fontconfig, XRandR) it loads at
// run time, so nothing else is needed to build.
//
// macOS compiles Metal shaders with Xcode's `metal` and `metallib`, from the
// Metal Toolchain component (once: xcodebuild -downloadComponent MetalToolchain).
// Only the release bundle uses the Keychain (development builds keep their
// key in a file; see platform_uses_keychain). Set UPPIES_SIGN_IDENTITY to a
// codesigning identity to sign with it instead of ad hoc: the Keychain then
// knows the app across rebuilds and doesn't ask again for the Uppies key.

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
#if OS == .WINDOWS {
    Windows_Resources :: #import "Windows_Resources";
    Ico_File          :: #import "Ico_File";
    #import "Windows";
    #import "Windows_Utf8";
    #import "d3d_compiler";
}
#if OS == .LINUX {
    POSIX            :: #import "POSIX";
    STB_Image        :: #import "stb_image";
    STB_Image_Resize :: #import "stb_image_resize";
    STB_Image_Write  :: #import "stb_image_write";
}

// The one place the version lives: the program gets it as APP_VERSION (the
// About panel, the User-Agent), and so does the macOS bundle's Info.plist.
APP_VERSION :: "1.0.2";

APP_NAME :: "Uppies";
APP_ID   :: "au.net.ruben.uppies";   // The macOS bundle identifier; the Linux desktop entry and icon name.

OUTPUT_DIR :: "bin";
EXE_NAME   :: "uppies";
ICON_FILE  :: "assets/icon.png";
#if OS == .WINDOWS { EXE_FILE :: "uppies.exe"; }
else { EXE_FILE :: "uppies"; }

build :: () {
    set_build_options_dc(.{do_output = false});

    release := false;
    run     := false;
    bundle  := false;
    for get_build_options().compile_time_command_line {
        if it == {
            case "release"; release = true;
            case "run";     run = true;
            case "bundle";
                bundle = true;
                release = true;   // Only release builds are packaged.
            case; log_error("Unknown build argument '%'. Valid: release, run, bundle\n", it);
        }
    }

    make_directory_if_it_does_not_exist(tprint("%/%", #filepath, OUTPUT_DIR), recursive = true);

    shader_source, shaders_ok := compile_shaders();
    if !shaders_ok return;
    #if OS == .LINUX {
        icon_source, icon_ok := window_icon_source();
        if !icon_ok return;
    }

    w := compiler_create_workspace(EXE_NAME);
    if !w {
        log_error("Could not create workspace.\n");
        return;
    }

    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.output_executable_name = EXE_NAME;
    options.output_path            = OUTPUT_DIR;
    options.intermediate_path      = ".build";
    set_optimization(*options, ifx release then .VERY_OPTIMIZED else .DEBUG);
    #if OS == .MACOS options.use_custom_link_command = true;   // See link_macos.
    set_build_options(options, w);

    #if OS == .WINDOWS {
        if release Windows_Resources.disable_runtime_console(w);
    }

    compiler_begin_intercept(w);
    add_build_string(tprint("APP_RELEASE :: %;\n", release), w);
    add_build_string(tprint("APP_BUNDLE :: %;\n", bundle), w);   // What ships: no -script or -selftest.
    add_build_string(tprint("APP_VERSION :: \"%\";\n", APP_VERSION), w);
    add_build_string(shader_source, w);
    #if OS == .LINUX add_build_string(icon_source, w);
    add_build_file(tprint("%/src/main.jai", #filepath), w);

    success := true;
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .ERROR;
                success = false;
            case .PHASE;
                phase := cast(*Message_Phase) message;
                if phase.phase == .POST_WRITE_EXECUTABLE && phase.executable_write_failed  success = false;
                #if OS == .MACOS {
                    if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                        if !link_macos(w, phase) success = false;
                    }
                }
            case .COMPLETE;
                complete := cast(*Message_Complete) message;
                if complete.error_code != .NONE  success = false;
                break;
        }
    }
    compiler_end_intercept(w);

    if !success return;

    #if OS == .WINDOWS {
        if !embed_icon() return;
    }
    copy_runtime_files();
    print("Built %/% (%)\n", OUTPUT_DIR, EXE_FILE, ifx release then "release" else "debug");

    exe := tprint("%/%/%", #filepath, OUTPUT_DIR, EXE_FILE);
    #if OS == .MACOS {
        if bundle {
            app, ok := make_app_bundle();
            if !ok return;
            print("Bundled %/%\n", OUTPUT_DIR, APP_BUNDLE);
            if !make_disk_image(app) return;
            exe = tprint("%/Contents/MacOS/%", app, EXE_FILE);
        }
    }
    #if OS == .WINDOWS {
        if bundle && !make_installer() return;
    }
    #if OS == .LINUX {
        if bundle && !make_tarball() return;
    }

    if run {
        run_command(exe, working_directory = path_strip_filename(exe), capture_and_return_output = false);
    }
}

// Each entry becomes a global byte array in the program, e.g.
// `shader_ui_vs: [N] u8`, holding the compiled bytecode.
Shader_Entry :: struct {
    name:   string;   // Global variable name in the program.
    file:   string;   // Relative to the repository root.
    entry:  string;
    target: string;
}

#if OS == .WINDOWS {
    SHADERS :: Shader_Entry.[
        .{"shader_ui_vs", "src/render/d3d11/ui.hlsl", "vs_main", "vs_5_0"},
        .{"shader_ui_ps", "src/render/d3d11/ui.hlsl", "ps_main", "ps_5_0"},
    ];
}

#if OS == .LINUX {
    // One GLSL file holds both stages (src/render/vulkan/ui.glsl), compiled
    // once per stage with that stage's macro defined. `entry` is the macro,
    // `target` the stage.
    VULKAN_SHADERS :: Shader_Entry.[
        .{"shader_ui_vert", "src/render/vulkan/ui.glsl", "VERTEX_SHADER",   "vert"},
        .{"shader_ui_frag", "src/render/vulkan/ui.glsl", "FRAGMENT_SHADER", "frag"},
    ];
}

#if OS == .MACOS {
    MACOS_MIN_VERSION :: "13.0";

    METAL_SHADERS :: Shader_Entry.[
        // One library holds every function; entry and target are unused.
        .{"shader_ui_metallib", "src/render/metal/ui.metal", "", ""},
    ];
}

compile_shaders :: () -> string, bool {
    builder: String_Builder;
    #if OS == .MACOS {
        developer_dir := find_developer_dir();
        intermediate := tprint("%/.build", #filepath);
        make_directory_if_it_does_not_exist(intermediate, recursive = true);
        for METAL_SHADERS {
            path := tprint("%/%", #filepath, it.file);
            air  := tprint("%/%.air", intermediate, it.name);
            lib  := tprint("%/%.metallib", intermediate, it.name);
            env  := tprint("DEVELOPER_DIR=%", developer_dir);
            if !run_tool("/usr/bin/env", env, "xcrun", "-sdk", "macosx", "metal", "-std=metal3.0", "-O3", "-Werror", tprint("-mmacosx-version-min=%", MACOS_MIN_VERSION), "-c", path, "-o", air) {
                log_error("Shader compilation failed (%). If the Metal Toolchain is missing, run:\n    xcodebuild -downloadComponent MetalToolchain\n", it.file);
                return "", false;
            }
            if !run_tool("/usr/bin/env", env, "xcrun", "-sdk", "macosx", "metallib", air, "-o", lib) {
                log_error("metallib failed (%).\n", it.file);
                return "", false;
            }
            bytes, ok := read_entire_file(lib);
            if !ok {
                log_error("Could not read %\n", lib);
                return "", false;
            }
            append_byte_array(*builder, it.name, cast([] u8) bytes);
        }
    }
    #if OS == .LINUX {
        intermediate := tprint("%/.build", #filepath);
        make_directory_if_it_does_not_exist(intermediate, recursive = true);
        glslc := find_program("glslc");
        glslang := ifx glslc then "" else find_program("glslangValidator");
        if !glslc && !glslang {
            log_error("No GLSL compiler found for the Vulkan shaders. Install glslc:\n    apt install glslc    (Debian, Ubuntu)\n    dnf install glslc    (Fedora)\n    pacman -S shaderc    (Arch)\nor glslang (glslangValidator).\n");
            return "", false;
        }
        for VULKAN_SHADERS {
            path := tprint("%/%", #filepath, it.file);
            spv  := tprint("%/%.spv", intermediate, it.name);
            ok: bool;
            if glslc ok = run_tool(glslc, tprint("-fshader-stage=%", it.target), tprint("-D%", it.entry), "--target-env=vulkan1.0", "-O", "-Werror", path, "-o", spv);
            else     ok = run_tool(glslang, "-V", "--target-env", "vulkan1.0", "-S", it.target, tprint("-D%", it.entry), path, "-o", spv);
            if !ok {
                log_error("Shader compilation failed (% %).\n", it.file, it.target);
                return "", false;
            }
            bytes, read_ok := read_entire_file(spv);
            if !read_ok || bytes.count % 4 != 0 {
                log_error("Could not read %\n", spv);
                return "", false;
            }
            // SPIR-V is 32-bit words, and vkCreateShaderModule wants it aligned to them.
            words: [] u32;
            words.data  = cast(*u32) bytes.data;
            words.count = bytes.count / 4;
            append_u32_array(*builder, it.name, words);
        }
    }
    #if OS == .WINDOWS {
        for SHADERS {
            path := tprint("%/%", #filepath, it.file);
            source, ok := read_entire_file(path);
            if !ok {
                log_error("Could not read shader %\n", path);
                return "", false;
            }
            flags := D3DCOMPILE.ENABLE_STRICTNESS | .OPTIMIZATION_LEVEL3 | .WARNINGS_ARE_ERRORS;
            bytecode, errors, hr := D3DCompile(source, path, .[], null, it.entry, it.target, xx flags, 0);
            if FAILED(hr) {
                log_error("Shader compilation failed (% %):\n%\n", it.file, it.entry, errors);
                return "", false;
            }
            append_byte_array(*builder, it.name, cast([] u8) bytecode);
        }
    }
    return builder_to_string(*builder), true;
}

append_byte_array :: (builder: *String_Builder, name: string, bytes: [] u8) {
    print_to_builder(builder, "% := u8.[", name);
    for bytes {
        if it_index % 32 == 0  append(builder, "\n    ");
        print_to_builder(builder, "%,", it);
    }
    append(builder, "\n];\n");
}

append_u32_array :: (builder: *String_Builder, name: string, words: [] u32) {
    print_to_builder(builder, "% := u32.[", name);
    for words {
        if it_index % 8 == 0  append(builder, "\n    ");
        print_to_builder(builder, "0x%,", formatInt(it, base = 16, minimum_digits = 8));
    }
    append(builder, "\n];\n");
}

// Writes <path>.sha256 beside a file a release ships: "<hash>  <file name>",
// the format sha256sum -c and shasum -c read. Uploaded with the release so a
// download can be checked against it. The OS's own tool does the hashing.
write_sha256_file :: (path: string) -> bool {
    hash: string;
    #if OS == .WINDOWS {
        // A header line, the hash (spaced in pairs on older Windows), a footer.
        _, out := run_command("certutil", "-hashfile", path, "SHA256", capture_and_return_output = true);
        for line: split(out, "\n",, temp) {
            candidate := replace(trim(line), " ", "",, temp);
            if is_sha256(candidate) { hash = candidate; break; }
        }
    } else {
        // "<hash>  <path>"
        #if OS == .LINUX  _, out := run_command("sha256sum", path, capture_and_return_output = true);
        else              _, out := run_command("shasum", "-a", "256", path, capture_and_return_output = true);
        found, first := split_from_left(trim(out), " ");
        if found hash = first;
    }
    if !is_sha256(hash) {
        log_error("Could not compute the SHA-256 of %\n", path);
        return false;
    }
    hash = to_lower_copy(hash,, temp);
    sum_file := tprint("%.sha256", path);
    if !write_entire_file(sum_file, tprint("%  %\n", hash, path_filename(path))) {
        log_error("Could not write %\n", sum_file);
        return false;
    }
    print("SHA-256 % (%)\n", hash, path_filename(sum_file));
    return true;
}

is_sha256 :: (s: string) -> bool {
    if s.count != 64 return false;
    for cast([] u8) s {
        if !((it >= #char "0" && it <= #char "9") || (it >= #char "a" && it <= #char "f") || (it >= #char "A" && it <= #char "F")) return false;
    }
    return true;
}

#if OS == .MACOS {
    // The Xcode that xcode-select names, unless that is only the Command Line
    // Tools, which have no Metal compiler.
    find_developer_dir :: () -> string {
        result, out := run_command("xcode-select", "-p", capture_and_return_output = true);
        dir := trim(out);
        if result.exit_code != 0 || !dir || contains(dir, "CommandLineTools") {
            dir = "/Applications/Xcode.app/Contents/Developer";
        }
        return dir;
    }

    // Jai's bundled lld can't read the .tbd stubs of recent macOS SDKs
    // (macOS 27 added architectures it doesn't know), so the executable is
    // linked with Apple's own linker, which always matches the SDK.
    link_macos :: (w: Workspace, m: *Message_Phase) -> bool {
        defer compiler_custom_link_command_is_complete(w);
        options := get_build_options(w);
        output := tprint("%/%", options.output_path, options.output_executable_name);

        _, sdk := run_command("xcrun", "--sdk", "macosx", "--show-sdk-path", capture_and_return_output = true);
        _, sdk_version := run_command("xcrun", "--sdk", "macosx", "--show-sdk-version", capture_and_return_output = true);
        args: [..] string;
        array_add(*args, "xcrun", "ld", "-arch", "arm64", "-o", output);
        array_add(*args, "-syslibroot", trim(sdk), "-platform_version", "macos", MACOS_MIN_VERSION, trim(sdk_version));
        array_add(*args, "-rpath", "@loader_path");
        for m.compiler_generated_object_files array_add(*args, it);
        for m.support_object_files            array_add(*args, it);
        for m.user_libraries                  array_add(*args, it);
        for m.system_libraries                array_add(*args, it);   // Already flags: -lSystem, -framework Metal...
        if !run_tool(.. args) {
            log_error("Link failed: %\n", get_quoted_command_string(args));
            compiler_set_workspace_status(.FAILED, w);
            return false;
        }
        identity := sign_identity();
        if identity != "-" && !run_tool("codesign", "--force", "--sign", identity, output) {
            log_error("codesign failed for %\n", output);
            compiler_set_workspace_status(.FAILED, w);
            return false;
        }
        return true;
    }

    // UPPIES_SIGN_IDENTITY, or "-" (ad hoc).
    sign_identity :: () -> string {
        POSIX :: #import "POSIX";
        identity := trim(to_string(POSIX.getenv("UPPIES_SIGN_IDENTITY")));
        return ifx identity then identity else "-";
    }

    APP_BUNDLE    :: "Uppies.app";
    APP_COPYRIGHT :: "© 2026 Ruben Bala";

    // bin/Uppies.app: the executable, data/ as resources, an icon made from
    // assets/icon.png, an Info.plist, and an ad-hoc signature (enough to run
    // on this Mac; sharing it needs a Developer ID signature and
    // notarization).
    make_app_bundle :: () -> path: string, ok: bool {
        root := tprint("%/%", #filepath, OUTPUT_DIR);
        app  := tprint("%/%", root, APP_BUNDLE);
        if is_directory(app) delete_directory(app);   // Nothing stale from an earlier bundle.
        macos     := tprint("%/Contents/MacOS", app);
        resources := tprint("%/Contents/Resources", app);
        make_directory_if_it_does_not_exist(macos, recursive = true);
        make_directory_if_it_does_not_exist(resources, recursive = true);

        if !copy_file(tprint("%/%", root, EXE_FILE), tprint("%/%", macos, EXE_FILE)) {
            log_error("Could not copy the executable into %\n", app);
            return "", false;
        }
        run_command("chmod", "+x", tprint("%/%", macos, EXE_FILE));
        data := tprint("%/data", #filepath);
        if is_directory(data) copy_directory(data, tprint("%/data", resources));

        if !make_icns(tprint("%/AppIcon.icns", resources)) return "", false;
        if !write_entire_file(tprint("%/Contents/Info.plist", app), info_plist()) {
            log_error("Could not write Info.plist\n");
            return "", false;
        }
        // Signing seals Info.plist and the resources to the executable;
        // Apple silicon won't run an unsigned app. Ad hoc unless
        // UPPIES_SIGN_IDENTITY names an identity.
        if !run_tool("codesign", "--force", "--sign", sign_identity(), "--timestamp=none", app) {
            log_error("codesign failed for %\n", app);
            return "", false;
        }
        return app, true;
    }

    // bin/Uppies-<version>-mac.dmg: Uppies.app beside a link to /Applications,
    // so opening the disk image shows where to drag it. Signed as the app is,
    // so the same caveat applies: without a Developer ID signature and
    // notarisation, Gatekeeper asks before opening it on another Mac.
    make_disk_image :: (app: string) -> bool {
        staging := tprint("%/.build/dmg", #filepath);
        // rm, not delete_directory: it never follows the link into /Applications.
        if !run_tool("rm", "-rf", staging) return false;
        make_directory_if_it_does_not_exist(staging, recursive = true);
        defer run_tool("rm", "-rf", staging);

        // ditto copies the bundle exactly as signed (links, modes, attributes).
        if !run_tool("ditto", app, tprint("%/%", staging, APP_BUNDLE)) {
            log_error("Could not copy % into the disk image\n", APP_BUNDLE);
            return false;
        }
        if !run_tool("ln", "-s", "/Applications", tprint("%/Applications", staging)) {
            log_error("Could not link Applications into the disk image\n");
            return false;
        }
        dmg := tprint("%/%/%-%-mac.dmg", #filepath, OUTPUT_DIR, APP_NAME, APP_VERSION);
        if !run_tool("hdiutil", "create", "-volname", tprint("% %", APP_NAME, APP_VERSION), "-srcfolder", staging, "-ov", "-format", "UDZO", dmg) {
            log_error("hdiutil could not make %\n", dmg);
            return false;
        }
        if !write_sha256_file(dmg) return false;
        print("Packaged %/%\n", OUTPUT_DIR, path_filename(dmg));
        return true;
    }

    // The 256 px master, resized to every size up to it.
    make_icns :: (output: string) -> bool {
        iconset := tprint("%/.build/AppIcon.iconset", #filepath);
        if is_directory(iconset) delete_directory(iconset);
        make_directory_if_it_does_not_exist(iconset, recursive = true);
        png := tprint("%/%", #filepath, ICON_FILE);
        SIZES :: struct { name: string; px: int; }.[
            .{"icon_16x16",      16}, .{"icon_16x16@2x",   32},
            .{"icon_32x32",      32}, .{"icon_32x32@2x",   64},
            .{"icon_128x128",   128}, .{"icon_128x128@2x", 256},
            .{"icon_256x256",   256},
        ];
        for SIZES {
            size := tprint("%", it.px);
            out  := tprint("%/%.png", iconset, it.name);
            result := run_command("sips", "-z", size, size, png, "--out", out, capture_and_return_output = true);
            if result.exit_code != 0 {
                log_error("sips could not make %\n", out);
                return false;
            }
        }
        if !run_tool("iconutil", "-c", "icns", iconset, "-o", output) {
            log_error("iconutil could not make %\n", output);
            return false;
        }
        return true;
    }

    info_plist :: () -> string {
        return tprint(#string PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>%2</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIdentifier</key>            <string>%3</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>%1</string>
    <key>CFBundleDisplayName</key>           <string>%1</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>%4</string>
    <key>CFBundleVersion</key>               <string>%4</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.finance</string>
    <key>LSMinimumSystemVersion</key>        <string>%5</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>      <string>%6</string>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST, APP_NAME, EXE_FILE, APP_ID, APP_VERSION, MACOS_MIN_VERSION, APP_COPYRIGHT);
    }
}

// Runs a build tool, showing what it printed; true if it succeeded.
run_tool :: (args: .. string) -> bool {
    result, out, err := run_command(.. args, capture_and_return_output = true);
    if out print("%", out);
    if err print("%", err);
    return result.type == .EXITED && result.exit_code == 0;
}

#if OS == .WINDOWS {
    // The 256 px master is resized to 256/128/48/32/16 and written into the
    // exe as icon group 1, which the window class loads (platform_windows.jai).
    // The same icon is kept in .build/uppies.ico for the installer.
    embed_icon :: () -> bool {
        png := tprint("%/%", #filepath, ICON_FILE);
        ico := Ico_File.create_ico_file_from_bitmap_filename(png);
        if !ico return false;
        defer free(ico);

        exe := tprint("%/%/%", #filepath, OUTPUT_DIR, EXE_FILE);
        if !Windows_Resources.set_icon_by_data(exe, ico, resource_id = 1) {
            log_error("Could not set the icon of %\n", exe);
            return false;
        }
        ico_file := tprint("%/.build/uppies.ico", #filepath);
        if !write_entire_file(ico_file, ico) {
            log_error("Could not write %\n", ico_file);
            return false;
        }
        return true;
    }

    // bin/Uppies-<version>-setup.exe, made by Inno Setup's command-line
    // compiler from installer/uppies.iss, which takes the files from bin/.
    // Neither the installer nor the exe is signed yet, so SmartScreen warns
    // the first time someone runs them.
    make_installer :: () -> bool {
        if !file_exists(tprint("%/installer/FTL.TXT", #filepath)) {
            print("Warning: installer/FTL.TXT is missing, so the installer ships freetype.dll without the FreeType License (see THIRD_PARTY.md).\n");
        }
        iscc   := find_iscc();
        script := tprint("%/installer/uppies.iss", #filepath);
        result, out, err := run_command(iscc, "/Q", tprint("/DAppVersion=%", APP_VERSION), script, capture_and_return_output = true);
        if result.type != .EXITED || result.exit_code != 0 {
            if out print("%", out);
            if err print("%", err);
            log_error("Inno Setup could not make the installer (ran %). Install Inno Setup 6 from https://jrsoftware.org/isinfo.php, or set UPPIES_ISCC to its ISCC.exe.\n", iscc);
            return false;
        }
        if !write_sha256_file(tprint("%/%/Uppies-%-setup.exe", #filepath, OUTPUT_DIR, APP_VERSION)) return false;
        print("Packaged %/Uppies-%-setup.exe\n", OUTPUT_DIR, APP_VERSION);
        return true;
    }

    // UPPIES_ISCC, else where Inno Setup 6 installs itself (for this user, or
    // for all users), else ISCC on the PATH.
    find_iscc :: () -> string {
        override := environment_variable("UPPIES_ISCC");
        if override return override;
        PLACES :: struct { variable: string; folder: string; }.[
            .{"LOCALAPPDATA",      "Programs/Inno Setup 6"},
            .{"ProgramFiles(x86)", "Inno Setup 6"},
            .{"ProgramFiles",      "Inno Setup 6"},
        ];
        for PLACES {
            base := environment_variable(it.variable);
            if !base continue;
            iscc := tprint("%/%/ISCC.exe", base, it.folder);
            if file_exists(iscc) return iscc;
        }
        return "ISCC.exe";
    }

    environment_variable :: (name: string) -> string {
        value := _wgetenv(cast(*s16) utf8_to_wide(name,, temp));
        if !value return "";
        return wide_to_utf8(cast(*u16) value,, temp);
    }
}

#if OS == .LINUX {
    // The window icon (_NET_WM_ICON) at the sizes window managers and task
    // switchers pick from, as `app_icon_pixels`: for each size its width,
    // height, then width * height pixels as 0xAARRGGBB, not premultiplied,
    // which is the property's own layout.
    WINDOW_ICON_SIZES :: s32.[16, 24, 32, 48, 64, 128];

    // The bundle's hicolor icons, for the desktop entry.
    BUNDLE_ICON_SIZES :: s32.[16, 24, 32, 48, 64, 128, 256];

    window_icon_source :: () -> string, bool {
        builder: String_Builder;
        print_to_builder(*builder, "app_icon_pixels := u32.[");
        for size: WINDOW_ICON_SIZES {
            rgba, ok := icon_rgba(size);
            if !ok return "", false;
            print_to_builder(*builder, "\n    %, %,", size, size);
            for i: 0..size * size - 1 {
                if i % 8 == 0  append(*builder, "\n    ");
                p := rgba.data + i * 4;
                argb := (cast(u32) p[3] << 24) | (cast(u32) p[0] << 16) | (cast(u32) p[1] << 8) | p[2];
                print_to_builder(*builder, "0x%,", formatInt(argb, base = 16, minimum_digits = 8));
            }
        }
        append(*builder, "\n];\n");
        return builder_to_string(*builder), true;
    }

    // assets/icon.png resized to size x size, RGBA (temporary storage).
    icon_rgba :: (size: s32) -> [] u8, bool {
        png := tprint("%/%", #filepath, ICON_FILE);
        w, h, channels: s32;
        pixels := STB_Image.stbi_load(temp_c_string(png), *w, *h, *channels, 4);
        if !pixels {
            log_error("Could not read %\n", png);
            return .[], false;
        }
        defer STB_Image.stbi_image_free(pixels);
        out := NewArray(size * size * 4, u8,, temp);
        // Filtered in linear light, weighted by alpha, as the icon tools on
        // the other platforms do.
        if !STB_Image_Resize.stbir_resize_uint8_srgb(pixels, w, h, 0, out.data, size, size, 0, 4, 3, 0) {
            log_error("Could not resize % to % px\n", png, size);
            return .[], false;
        }
        return out, true;
    }

    // bin/Uppies-<version>-linux-x86_64.tar.gz: one folder holding the
    // executable, data/, the icons, install.sh (which puts the app in
    // ~/.local and adds it to the desktop's menus) and the licenses.
    make_tarball :: () -> bool {
        name    := tprint("%-%-linux-x86_64", APP_NAME, APP_VERSION);
        staging := tprint("%/.build/tarball", #filepath);
        root    := tprint("%/%", staging, name);
        if !run_tool("rm", "-rf", staging) return false;
        make_directory_if_it_does_not_exist(root, recursive = true);

        bin := tprint("%/%", #filepath, OUTPUT_DIR);
        if !copy_file(tprint("%/%", bin, EXE_FILE), tprint("%/%", root, EXE_FILE)) {
            log_error("Could not copy the executable into %\n", root);
            return false;
        }
        run_tool("chmod", "755", tprint("%/%", root, EXE_FILE));
        if is_directory(tprint("%/data", bin)) copy_directory(tprint("%/data", bin), tprint("%/data", root));

        installer := tprint("%/installer/linux/install.sh", #filepath);
        if !copy_file(installer, tprint("%/install.sh", root)) {
            log_error("Could not copy %\n", installer);
            return false;
        }
        run_tool("chmod", "755", tprint("%/install.sh", root));
        copy_file(tprint("%/LICENSE", #filepath), tprint("%/LICENSE", root));
        copy_file(tprint("%/THIRD_PARTY.md", #filepath), tprint("%/THIRD_PARTY.md", root));
        // FreeType is linked into the executable, so its license goes with it.
        ftl := tprint("%/installer/FTL.TXT", #filepath);
        if file_exists(ftl) copy_file(ftl, tprint("%/FTL.TXT", root));
        else print("Warning: installer/FTL.TXT is missing, so the tarball ships FreeType without the FreeType License (see THIRD_PARTY.md).\n");

        for size: BUNDLE_ICON_SIZES {
            rgba, ok := icon_rgba(size);
            if !ok return false;
            dir := tprint("%1/icons/hicolor/%2x%2/apps", root, size);
            make_directory_if_it_does_not_exist(dir, recursive = true);
            path := tprint("%/%.png", dir, APP_ID);
            if !STB_Image_Write.stbi_write_png(temp_c_string(path), size, size, 4, rgba.data, size * 4) {
                log_error("Could not write %\n", path);
                return false;
            }
        }

        tarball := tprint("%/%.tar.gz", bin, name);
        // Owned by root in the archive, so extracting it never asks to keep
        // the uid of whoever built it.
        if !run_tool("tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", tarball, "-C", staging, name) {
            log_error("tar could not make %\n", tarball);
            return false;
        }
        run_tool("rm", "-rf", staging);
        if !write_sha256_file(tarball) return false;
        print("Packaged %/%\n", OUTPUT_DIR, path_filename(tarball));
        return true;
    }

    // The program's full path, searched for on the PATH like a shell would;
    // empty if it isn't there.
    find_program :: (name: string) -> string {
        path := to_string(POSIX.getenv("PATH"));
        for dir: split(path, ":",, temp) {
            if !dir continue;
            candidate := tprint("%/%", dir, name);
            if file_exists(candidate) return candidate;
        }
        return "";
    }
}

// Data (fonts, images) lives in data/ at the repo root; mirror it next to the
// exe. FreeType is the only runtime DLL (on Windows; it links statically on
// macOS and Linux).
copy_runtime_files :: () {
    compiler_dir := tprint("%/modules", compiler_get_base_path());
    #if OS == .WINDOWS {   // FreeType links statically elsewhere.
        DLLS :: string.["freetype/windows/freetype.dll"];
        for DLLS {
            src := tprint("%/%", compiler_dir, it);
            dst := tprint("%/%/%", #filepath, OUTPUT_DIR, path_filename(it));
            if !file_exists(dst) && !copy_file(src, dst) log_error("Could not copy % to %\n", src, dst);
        }
    }

    src_data := tprint("%/data", #filepath);
    if is_directory(src_data) {
        dst_data := tprint("%/%/data", #filepath, OUTPUT_DIR);
        copy_directory(src_data, dst_data);
    }
}

#run build();
