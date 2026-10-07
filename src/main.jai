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
#import "Sort";
#import "Thread";
#import "Clipboard";
#if OS == .WINDOWS {
    #import "Windows";
    #import "Windows_Utf8";
    #import "d3d11"()(INCLUDE_DEBUG_BINDINGS = false);
    #import "dxgi";
}
FT :: #import "freetype";

#load "core/math.jai";
#load "core/time.jai";
#load "core/format.jai";
#load "core/json.jai";
#load "core/png.jai";
#load "core/pdf.jai";
#load "platform/platform.jai";
#load "net/http_windows.jai";
#load "up/model.jai";
#load "up/store.jai";
#load "up/store_file.jai";
#load "up/client.jai";
#load "up/demo.jai";
#load "selftest.jai";
#load "render/draw.jai";
#load "render/font.jai";
#load "render/renderer.jai";
#load "ui/theme.jai";
#load "ui/ui.jai";
#load "ui/text_input.jai";
#load "app/app.jai";
#load "app/settings.jai";
#load "app/sync.jai";
#load "app/local_data.jai";
#load "app/analytics.jai";
#load "app/common.jai";
#load "app/widgets.jai";
#load "app/charts.jai";
#load "app/inspector.jai";
#load "app/print.jai";
#load "app/print_transaction.jai";
#load "app/page_overview.jai";
#load "app/page_transactions.jai";
#load "app/page_accounts.jai";
#load "app/page_spending.jai";
#load "app/page_tags.jai";
#load "app/page_webhooks.jai";
#load "app/page_settings.jai";
#load "app/script.jai";

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

    // -selftest | -demo | -size WxH | -script "steps" (see app/script.jai)
    // -data-dir PATH: keep settings, token and data there, even when
    //                 scripted (tests); -cache-demo: store sample data too.
    args := get_command_line_arguments();
    width, height := 1360, 860;
    start_demo := false;
    hidden := false;
    start_page := "";
    continuous := false;
    quit_after: float64 = -1;   // Seconds; reports how many frames were drawn.
    data_dir := "";
    for args {
        if it == "-selftest" exit(cast(s32) selftest());
        if it == "-demo" start_demo = true;
        if it == "-size" && it_index + 1 < args.count {
            found, w, h := split_from_left(args[it_index + 1], "x");
            if found { width = string_to_int(w); height = string_to_int(h); }
        }
        if it == "-script" && it_index + 1 < args.count script_load(args[it_index + 1]);
        if it == "-hidden" hidden = true;
        if it == "-continuous" continuous = true;
        if it == "-page" && it_index + 1 < args.count start_page = args[it_index + 1];
        if it == "-data-dir" && it_index + 1 < args.count data_dir = args[it_index + 1];
        if it == "-cache-demo" local_data.cache_demo = true;
        if it == "-quit-after" && it_index + 1 < args.count {
            quit_after = string_to_float(args[it_index + 1]);
            persist_enabled = false;
        }
    }

    if data_dir.count {
        platform_set_app_data_dir(data_dir);
        persist_enabled = true;
    }

    if !platform_init("Uppies", width, height) exit(1);
    defer platform_shutdown();

    if !renderer_init() exit(1);
    defer renderer_shutdown();

    if !fonts_init() || !theme_load_fonts() exit(1);
    defer fonts_shutdown();

    app_init(start_demo);
    app.continuous_rendering = continuous;
    for PAGE_TITLES if to_lower_temp(it) == to_lower_temp(start_page) { select_page(cast(Page) it_index); app.keep_page = true; }
    platform.modal_frame = modal_frame;

    // Draw the first frame before the window appears, so it never shows
    // an empty or white client area.
    clock.last_time = seconds_since_init();
    clock.resumed = true;
    renderer_wait_for_frame();
    run_frame();
    if !script.active && !hidden platform_show_window();   // Scripted runs stay off screen.
    frames_at_start := clock.frame_count;
    late_start: s64 = -1;   // Frame count five seconds before a timed run ends.
    late_cpu_ms, late_cpu_max: float;

    last_dpi_scale := platform.dpi_scale;
    while !platform.quit_requested {
        if quit_after > 0 {
            t := seconds_since_init();
            if late_start < 0 && t >= quit_after - 5 late_start = clock.frame_count;
            if late_start >= 0 { late_cpu_ms += clock.cpu_ms; late_cpu_max = max(late_cpu_max, clock.cpu_ms); }
            if t >= quit_after {
                late := clock.frame_count - max(late_start, 0);
                log("Frames drawn: % in % s; % in the last 5 s (CPU % ms average, % ms worst).\n", clock.frame_count - frames_at_start, cast(int) quit_after, late,
                    formatFloat(late_cpu_ms / max(late, 1), trailing_width = 3), formatFloat(late_cpu_max, trailing_width = 3));
                break;
            }
        }
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
            // Sleep until input arrives, or until something asked for a
            // frame at a given time (a caret blink, a timer).
            timeout: float64 = -1;
            if ui.wake_at > 0 timeout = max(ui.wake_at - seconds_since_init(), 0);
            if quit_after > 0 timeout = ifx timeout < 0 then quit_after - seconds_since_init() else min(timeout, quit_after - seconds_since_init());
            timeout = ifx quit_after > 0 then max(timeout, 0.0) else timeout;
            platform_wait_for_events(timeout);
            clock.resumed = true;
            continue;
        }

        // Every wait is paired with a present (run_frame), or the swap
        // chain's latency budget drifts.
        renderer_wait_for_frame();
        platform_pump_events();   // Input that arrived while waiting makes this frame.
        // A modal loop entered during the pump (the window being dragged)
        // may have drawn and presented frames itself: wait again if so.
        renderer_wait_for_frame();
        run_frame();

        if !renderer_settings.vsync && app.max_fps > 0 {
            platform_sleep_until(clock.last_time + 1.0 / app.max_fps);
        }
    }
    local_data_shutdown();
}

// Something to show: input arrived, an animation is in flight, or the app
// renders continuously (benchmarking).
wants_frame :: () -> bool {
    return platform.needs_redraw || clock.settle_frames > 0 || ui.animating || app.continuous_rendering || script.active;
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

    script_frame();
    fonts_begin_frame();
    draw_begin_frame(xx platform.width, xx platform.height);
    ui_begin_frame(clock.dt, now);   // Wall clock for timers; animations step by dt.
    app_frame();
    ui_end_frame();
    input_end_frame();
    draw_end_frame();

    renderer_render(theme.background);
    clock.cpu_ms = cast(float) ((seconds_since_init() - now) * 1000);
    script_after_render();
    renderer_present();
}
