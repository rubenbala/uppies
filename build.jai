// Build metaprogram for Uppies.
//
//     jai build.jai                 debug build   -> bin/uppies.exe
//     jai build.jai - release       optimized build (no console window)
//     jai build.jai - run           build, then launch the app
//
// Shaders are compiled here, at build time, and their bytecode is embedded
// in the executable: no shader compiler ships with the app, startup never
// waits on compilation, and a shader error is a build error. The icon is
// embedded the same way, from assets/icon.png.

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
    #import "d3d_compiler";
}

OUTPUT_DIR :: "bin";
EXE_NAME   :: "uppies";
ICON_FILE  :: "assets/icon.png";
#if OS == .WINDOWS { EXE_FILE :: "uppies.exe"; }
else { EXE_FILE :: "uppies"; }

build :: () {
    set_build_options_dc(.{do_output = false});

    release := false;
    run     := false;
    for get_build_options().compile_time_command_line {
        if it == {
            case "release"; release = true;
            case "run";     run = true;
            case; log_error("Unknown build argument '%'. Valid: release, run\n", it);
        }
    }

    make_directory_if_it_does_not_exist(tprint("%/%", #filepath, OUTPUT_DIR), recursive = true);

    shader_source, shaders_ok := compile_shaders();
    if !shaders_ok return;

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
    set_build_options(options, w);

    #if OS == .WINDOWS {
        if release Windows_Resources.disable_runtime_console(w);
    }

    compiler_begin_intercept(w);
    add_build_string(tprint("APP_RELEASE :: %;\n", release), w);
    add_build_string(shader_source, w);
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

    if run {
        exe := tprint("%/%/%", #filepath, OUTPUT_DIR, EXE_FILE);
        run_command(exe, working_directory = tprint("%/%", #filepath, OUTPUT_DIR), capture_and_return_output = false);
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

compile_shaders :: () -> string, bool {
    builder: String_Builder;
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
            print_to_builder(*builder, "% := u8.[", it.name);
            for byte, index: cast([] u8) bytecode {
                if index % 32 == 0  append(*builder, "\n    ");
                print_to_builder(*builder, "%,", byte);
            }
            append(*builder, "\n];\n");
        }
    }
    return builder_to_string(*builder), true;
}

#if OS == .WINDOWS {
    // The 256 px master is resized to 256/128/48/32/16 and written into the
    // exe as icon group 1, which the window class loads (platform_windows.jai).
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
        return true;
    }
}

// Data (fonts, images) lives in data/ at the repo root; mirror it next to the
// exe. FreeType is the only runtime DLL.
copy_runtime_files :: () {
    compiler_dir := tprint("%/modules", compiler_get_base_path());
    #if OS == .WINDOWS {
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
