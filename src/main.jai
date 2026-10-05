// Uppies: a desktop app on Jai and Direct3D.
//
// Frame structure (see run_frame):
//
//   wait until the display can take a frame -> pump OS events -> build the
//   UI (which draws into the draw list) -> one instanced draw -> present.
//
// Waiting *before* reading input keeps latency to a single frame. When
// nothing changes and nothing animates, the loop sleeps in the OS until the
// next event: an idle window uses no CPU or GPU at all.
//
// Layers, each using only those below it:
//
//   app/        the screens
//   ui/         immediate-mode widgets, animation state, theme
//   render/     draw list, fonts, graphics backends (d3d11/)
//   platform/   window, input, OS services (platform_windows.jai)
//   core/       math, rectangles, colors, animation curves

#import "Basic";
#import "Math";
#import "String";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "System";
#if OS == .WINDOWS {
    #import "Windows";
    #import "Windows_Utf8";
    #import "d3d11"()(INCLUDE_DEBUG_BINDINGS = false);
    #import "dxgi";
}
FT :: #import "freetype";

#load "core/math.jai";
#load "platform/platform.jai";
#load "render/draw.jai";
#load "render/font.jai";
#load "render/renderer.jai";
#load "ui/theme.jai";
#load "ui/ui.jai";
#load "app/app.jai";

MAX_FRAME_DT :: 0.1;   // Longer frames (a hitch, a breakpoint) don't jump animations.

Frame_Clock :: struct {
    last_time:      float64;
    time:           float64;   // Animation time, seconds.
    dt:             float;
    resumed:        bool;      // The loop just woke from sleeping.
    settle_frames:  int;
    frame_count:    s64;
    cpu_ms:         float;     // Time spent building and submitting the last frame.
    frame_interval_ms: float;  // Time between the last two frames.
}

clock: Frame_Clock;
exe_dir: string;

main :: () {
    exe_dir = copy_string(path_strip_filename(get_path_of_running_executable()));
    while exe_dir.count && (exe_dir[exe_dir.count - 1] == #char "/" || exe_dir[exe_dir.count - 1] == #char "\\") exe_dir.count -= 1;
    set_working_directory(exe_dir);

    if !platform_init("Uppies", 1280, 800) exit(1);
    defer platform_shutdown();

    if !renderer_init() exit(1);
    defer renderer_shutdown();

    if !fonts_init() || !theme_load_fonts() exit(1);
    defer fonts_shutdown();

    app_init();
    platform.modal_frame = modal_frame;

    // Draw the first frame before the window appears, so it never shows
    // an empty or white client area.
    clock.last_time = seconds_since_init();
    clock.resumed = true;
    renderer_wait_for_frame();
    run_frame();
    platform_show_window();

    last_dpi_scale := platform.dpi_scale;
    while !platform.quit_requested {
        reset_temporary_storage();
        platform_pump_events();
        if platform.quit_requested break;

        if platform.dpi_scale != last_dpi_scale {
            // Moved to a monitor with another scale: glyphs re-rasterize at
            // the new pixel sizes.
            last_dpi_scale = platform.dpi_scale;
            fonts_clear_cache();
        }

        if platform.minimized || !wants_frame() {
            platform_wait_for_events();
            clock.resumed = true;
            continue;
        }

        // Every wait is paired with a present (run_frame), or the swap
        // chain's latency budget drifts.
        renderer_wait_for_frame();
        platform_pump_events();   // Input that arrived while waiting makes this frame.
        run_frame();

        if !renderer_settings.vsync && app.max_fps > 0 {
            platform_sleep_until(clock.last_time + 1.0 / app.max_fps);
        }
    }
}

// Something to show: input arrived, an animation is in flight, or the app
// renders continuously (benchmarking).
wants_frame :: () -> bool {
    return platform.needs_redraw || clock.settle_frames > 0 || ui.animating || app.continuous_rendering;
}

// Frames that Win32's modal move/resize loop asks for (see platform_windows).
modal_frame :: () {
    if platform.minimized return;
    renderer_wait_for_frame();
    run_frame();
}

run_frame :: () {
    now := seconds_since_init();
    interval := now - clock.last_time;
    clock.last_time = now;
    dt := interval;
    // Waking from sleep, the time since the last frame says nothing about
    // how long this frame will be on screen: assume one refresh.
    if clock.resumed dt = 1.0 / platform.refresh_hz;
    clock.resumed = false;
    dt = clamp(dt, 0, MAX_FRAME_DT);
    clock.dt = cast(float) dt;
    clock.time += dt;
    clock.frame_count += 1;
    clock.frame_interval_ms = cast(float) (interval * 1000);

    // Immediate-mode UI settles one frame after input (a click can change
    // what is drawn above the widget that took it), so input buys two frames.
    if platform.needs_redraw clock.settle_frames = 1;
    else if clock.settle_frames > 0 clock.settle_frames -= 1;
    platform.needs_redraw = false;   // Input arriving from here on is for the next frame.

    fonts_begin_frame();
    draw_begin_frame(xx platform.width, xx platform.height);
    ui_begin_frame(clock.dt, clock.time);
    app_frame();
    ui_end_frame();
    input_end_frame();

    renderer_render(theme.background);
    clock.cpu_ms = cast(float) ((seconds_since_init() - now) * 1000);
    renderer_present();
}
