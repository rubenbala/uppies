// The app: a sidebar, pages of panels, buttons and text, and a status bar.
// Doubles as a showcase and a benchmark for the UI stack: the Overview page
// shows live frame timings and what the GPU is being sent.

Page :: enum u8 { OVERVIEW; PROJECTS; ACTIVITY; SETTINGS; }

PAGE_TITLES    :: string.["Overview", "Projects", "Activity", "Settings"];
PAGE_SUBTITLES :: string.[
    "Jai and Direct3D 11. Every frame is a single instanced draw call.",
    "Everything you are building, in one place.",
    "What happened recently across your workspace.",
    "Rendering and animation options.",
];

HISTORY :: 90;

App :: struct {
    page: Page;
    page_t: float = 1;              // 0 -> 1 as a newly selected page comes in.
    nav_spring: Spring;             // Selection pill position, in nav rows.
    intro_time: float;              // Seconds since startup, for the entrance.

    scroll: float;                  // Logical units.
    scroll_target: float;
    content_height: float;          // Of the current page, measured last frame.
    was_animating: bool;            // Last frame's ui.animating: this frame's is still being decided.

    continuous_rendering: bool;     // Render every frame even when idle.
    max_fps: float;                 // With vsync off; 0 = uncapped.
    animation_speed: float = 1;

    // Animation showcase.
    demo_time: float;
    demo_playing := true;
    demo_bars: [7] Spring;
    demo_progress: float;
    demo_progress_target := 0.72;
    demo_seed: u32 = 12345;

    // Frame timing history (ring buffers).
    cpu_ms:      [HISTORY] float;
    interval_ms: [HISTORY] float;
    history_at:  int;
    shown_cpu_ms: float;            // Smoothed for display.
    shown_fps:    float;
}

app: App;

app_init :: () {
    app.nav_spring.value = 0;
    for * app.demo_bars it.value = 0.1;
    randomize_demo_bars();
}

app_frame :: () {
    dt := ui.dt;
    app.intro_time += dt;
    if app.intro_time < 1.5 ui.animating = true;

    record_timings();
    handle_hotkeys();

    full := rect(0, 0, xx platform.width, xx platform.height);
    status := cut_bottom(*full, px(30));
    sidebar := cut_left(*full, px(236));

    draw_sidebar(sidebar);
    draw_content(full);
    draw_status_bar(status);
    app.was_animating = ui.animating;
}

#scope_file

handle_hotkeys :: () {
    if letter_pressed(#char "V") renderer_settings.vsync = !renderer_settings.vsync;
    if letter_pressed(#char "C") app.continuous_rendering = !app.continuous_rendering;
    if key_down(.CONTROL) {
        for 0..3 if letter_pressed(cast(u8) (#char "1" + it)) select_page(cast(Page) it);
    }
}

select_page :: (page: Page) {
    if page == app.page return;
    app.page = page;
    app.page_t = 0;
    app.scroll = 0;
    app.scroll_target = 0;
}

record_timings :: () {
    app.cpu_ms[app.history_at]      = clock.cpu_ms;
    app.interval_ms[app.history_at] = clock.frame_interval_ms;
    app.history_at = (app.history_at + 1) % HISTORY;
    app.shown_cpu_ms = damp(app.shown_cpu_ms, clock.cpu_ms, 6, ui.dt);
    if clock.frame_interval_ms > 0 && !clock.resumed {
        fps := 1000.0 / max(clock.frame_interval_ms, 0.01);
        app.shown_fps = damp(app.shown_fps, fps, 4, ui.dt);
    }
}

//
// Sidebar.
//

NAV_ROW_HEIGHT :: 38.0;

draw_sidebar :: (area: Rect) {
    draw_rect(area, theme.sidebar);
    draw_rect(snap(rect(area.x + area.w - px(1), area.y, px(1), area.h)), theme.divider);

    r := rect_inset_xy(area, px(14), px(18));

    // Brand.
    brand := cut_top(*r, px(36));
    logo := snap(rect(brand.x + px(6), brand.y + px(4), px(28), px(28)));
    draw_shadow(logo, px(8), px(10), color_with_alpha(theme.accent, 0.45), 0, px(3));
    draw_rect_ex(logo, theme.accent_top, theme.accent_bottom, .[px(8), px(8), px(8), px(8)], hairline(), rgba(0xFFFFFF, 50));
    draw_up_arrow(logo, theme.on_accent);
    draw_text_in_rect(fonts.semibold, px(17), rect(logo.x + logo.w + px(12), brand.y, px(150), brand.h), "Uppies", theme.text);

    cut_top(*r, px(26));
    section := cut_top(*r, px(22));
    draw_text_in_rect(fonts.semibold, px(11), rect_inset_xy(section, px(10), 0), "WORKSPACE", theme.text_muted);
    cut_top(*r, px(4));

    // Navigation. The selection pill springs to the chosen row.
    rows := cut_top(*r, px(NAV_ROW_HEIGHT) * 4);
    pill_row := ui_spring(*app.nav_spring, xx app.page, 380, 0.78);
    pill := snap(rect(rows.x, rows.y + pill_row * px(NAV_ROW_HEIGHT), rows.w, px(NAV_ROW_HEIGHT - 2)));
    draw_rect(pill, theme.surface_hover, px(theme.radius_control));
    draw_rect(snap(rect(pill.x, pill.y + px(9), px(3), pill.h - px(18))), theme.accent, px(1.5));

    for 0..3 {
        row := cut_top(*rows, px(NAV_ROW_HEIGHT));
        row.h -= px(2);
        page := cast(Page) it;
        if nav_item(row, page) select_page(page);
    }

    // Footer card.
    footer := cut_bottom(*r, px(92));
    ui_panel(footer, 0.0, theme.surface);
    inner := rect_inset_xy(footer, px(14), px(14));
    line := cut_top(*inner, px(20));
    draw_circle(line.x + px(4), line.y + line.h * 0.5, px(4), theme.success);
    draw_text_in_rect(fonts.semibold, px(13), rect(line.x + px(16), line.y, line.w, line.h), "Renderer healthy", theme.text);
    cut_top(*inner, px(6));
    draw_text_in_rect(fonts.regular, px(12), cut_top(*inner, px(18)), tprint("% instances, 1 draw call", renderer_stats.instances), theme.text_secondary);
    draw_text_in_rect(fonts.regular, px(12), cut_top(*inner, px(18)), tprint("Idle CPU when nothing moves"), theme.text_muted);
}

nav_item :: (r: Rect, page: Page) -> bool {
    label := PAGE_TITLES[page];
    id := ui_id("nav", xx page);
    w := ui_widget(id);
    io := ui_interact(id, r);
    selected := app.page == page;
    ui_animate(*w.hover, ifx io.hovered && !selected then 1.0 else 0.0, 18);
    ui_animate(*w.press, ifx selected then 1.0 else 0.0, 14);
    if io.hovered ui.cursor = .HAND;

    if w.hover > 0 draw_rect(snap(r), color_with_alpha(theme.surface_hover, 0.6 * w.hover), px(theme.radius_control));

    color := color_lerp(theme.text_secondary, theme.text, max(w.press, w.hover));
    icon_color := color_lerp(theme.text_muted, theme.accent_top, w.press);
    icon := snap(rect(r.x + px(12), r.y + (r.h - px(16)) * 0.5, px(16), px(16)));
    draw_page_icon(page, icon, color_lerp(icon_color, theme.text, w.hover * 0.5));
    draw_text_in_rect(fonts.regular, px(14), rect(r.x + px(40), r.y, r.w - px(40), r.h), label, color);
    return io.clicked;
}

// Little icons made of the same rounded rectangles as everything else.
draw_page_icon :: (page: Page, r: Rect, color: Color) {
    s := r.w;
    if page == {
        case .OVERVIEW;
            g := s * 0.42;
            gap := s - 2 * g;
            for y: 0..1 for x: 0..1 draw_rect(rect(r.x + x * (g + gap), r.y + y * (g + gap), g, g), color, px(2));
        case .PROJECTS;
            h := s * 0.22;
            for 0..2 draw_rect(rect(r.x, r.y + it * (h + (s - 3 * h) / 2), s - it * s * 0.2, h), color, h * 0.5);
        case .ACTIVITY;
            heights := float.[0.45, 0.9, 0.65, 0.3];
            bw := s * 0.16;
            for heights {
                bh := s * it;
                draw_rect(rect(r.x + it_index * (s - bw) / 3.0, r.y + s - bh, bw, bh), color, bw * 0.5);
            }
        case .SETTINGS;
            cx, cy := r.x + s * 0.5, r.y + s * 0.5;
            draw_circle(cx, cy, s * 0.5, color);
            draw_circle(cx, cy, s * 0.28, theme.sidebar);
            draw_circle(cx, cy, s * 0.13, color);
    }
}

draw_up_arrow :: (r: Rect, color: Color) {
    cx := r.x + r.w * 0.5;
    stem_w := r.w * 0.14;
    draw_rect(rect(cx - stem_w * 0.5, r.y + r.h * 0.34, stem_w, r.h * 0.42), color, stem_w * 0.5);
    // Chevron from stacked bars: wider as they go down.
    for 0..3 {
        t := it / 3.0;
        w := stem_w + r.w * 0.36 * t;
        draw_rect(rect(cx - w * 0.5, r.y + r.h * (0.24 + 0.075 * it), w, stem_w * 0.9), color, stem_w * 0.45);
    }
}

//
// Content.
//

draw_content :: (area: Rect) {
    ui_animate(*app.page_t, 1, 10);
    t := ease_out_cubic(app.page_t);

    // Header.
    r := rect_inset_xy(area, px(32), 0);
    header := cut_top(*r, px(96));
    title_y := header.y + px(44);
    push_opacity(t);
    draw_text(fonts.semibold, px(theme.font_size_title), header.x, title_y + px(6) * (1 - t), PAGE_TITLES[app.page], theme.text);
    draw_text(fonts.regular, px(theme.font_size_body), header.x, title_y + px(26) + px(6) * (1 - t), PAGE_SUBTITLES[app.page], theme.text_secondary);
    pop_opacity();

    buttons := header;
    buttons.y += px(30);
    buttons.h = px(theme.control_height);
    if ui_button("New project", cut_right(*buttons, button_width("New project")), .PRIMARY) {
        select_page(.PROJECTS);
    }
    cut_right(*buttons, px(10));
    if ui_button("Share", cut_right(*buttons, button_width("Share")), .SECONDARY) {}
    ui_divider(area.x, header.y + header.h - px(1), area.w);

    // Scrollable body, clipped below the header.
    view := rect(area.x, header.y + header.h, area.w, area.y + area.h - (header.y + header.h));
    if input.mouse_inside && rect_contains(view, input.mouse_x, input.mouse_y) && input.wheel != 0 {
        app.scroll_target -= input.wheel * 90;
    }
    max_scroll := max(app.content_height - view.h / ui.scale, 0.0);
    app.scroll_target = clamp(app.scroll_target, 0, max_scroll);
    ui_animate(*app.scroll, app.scroll_target, 16);

    push_clip(view);
    push_opacity(t);
    body := rect_inset_xy(view, px(32), px(24));
    body.y += px(14) * (1 - t) - px(app.scroll);
    body.h = 1_000_000;   // Pages lay out top-down without limit; the clip cuts them.
    top := body.y;
    bottom: float;
    if app.page == {
        case .OVERVIEW; bottom = draw_overview(body);
        case .PROJECTS; bottom = draw_projects(body);
        case .ACTIVITY; bottom = draw_activity(body);
        case .SETTINGS; bottom = draw_settings(body);
    }
    app.content_height = (bottom - top) / ui.scale + 48;
    pop_opacity();
    pop_clip();

    if max_scroll > 0 draw_scrollbar(view, max_scroll);
}

draw_scrollbar :: (view: Rect, max_scroll: float) {
    track := rect(view.x + view.w - px(8), view.y + px(6), px(4), view.h - px(12));
    visible := view.h / (view.h + px(max_scroll));
    thumb_h := max(track.h * visible, px(32));
    thumb_y := track.y + (track.h - thumb_h) * (app.scroll / max_scroll);
    draw_rect(rect(track.x, thumb_y, track.w, thumb_h), theme.border_strong, track.w * 0.5);
}

// Cards rise into place one after another when the app starts.
intro :: (index: int) -> float {
    return ease_out_cubic((app.intro_time - 0.08 - index * 0.07) / 0.55);
}

card :: (area: Rect, title: string, index: int) -> Rect {
    t := intro(index);
    r := area;
    r.y += px(16) * (1 - t);
    push_opacity(t);
    ui_panel(r);
    inner := rect_inset_xy(r, px(22), px(18));
    if title.count {
        head := cut_top(*inner, px(22));
        draw_text_in_rect(fonts.semibold, px(15), head, title, theme.text);
        cut_top(*inner, px(14));
    }
    return inner;
}

card_end :: () { pop_opacity(); }

draw_overview :: (body: Rect) -> float {
    r := body;
    gap := px(18);
    width := body.w / ui.scale;   // Logical units, for the breakpoints.

    // Stat tiles: three across, or stacked when narrow.
    columns := ifx width >= 760 then 3 else 1;
    tile_h := px(ifx columns == 3 then 148.0 else 116.0);
    tiles: [3] Rect;
    if columns == 3 {
        row := cut_top(*r, tile_h);
        for 0..2 tiles[it] = split_columns(row, 3, gap, it);
    } else {
        for 0..2 {
            if it cut_top(*r, gap);
            tiles[it] = cut_top(*r, tile_h);
        }
    }

    inner := card(tiles[0], "", 0);
    stat_tile(inner, "Frame time (CPU)", tprint("% ms", formatFloat(app.shown_cpu_ms, trailing_width = 2, zero_removal = .NO)), "Build UI + submit, per frame", app.cpu_ms, 2.0, theme.accent_top);
    card_end();

    inner = card(tiles[1], "", 1);
    animating := app.was_animating || app.continuous_rendering;
    fps_text := ifx animating then tprint("% fps", cast(int) (app.shown_fps + 0.5)) else "Idle";
    sub := tprint("% Hz display, vsync %", cast(int) (platform.refresh_hz + 0.5), ifx renderer_settings.vsync then "on" else "off");
    stat_tile(inner, "Frame rate", fps_text, sub, app.interval_ms, 1000.0 / platform.refresh_hz * 1.5, theme.success);
    card_end();

    inner = card(tiles[2], "", 2);
    kb := renderer_stats.upload_bytes / 1024.0;
    stat_tile(inner, "GPU work", tprint("% draw call", renderer_stats.draw_calls), tprint("% instances, % KB uploaded", renderer_stats.instances, formatFloat(kb, trailing_width = 1, zero_removal = .NO)), .[], 1, theme.warning);
    card_end();

    // Controls beside the animation, or above it when narrow.
    cut_top(*r, gap);
    if width >= 900 {
        row := cut_top(*r, px(300));
        left := cut_left(*row, (row.w - gap) * 0.42);
        cut_left(*row, gap);
        draw_controls_card(left, 3);
        draw_animation_card(row, 4);
    } else {
        draw_controls_card(cut_top(*r, px(300)), 3);
        cut_top(*r, gap);
        draw_animation_card(cut_top(*r, px(300)), 4);
    }

    cut_top(*r, gap);
    typo := cut_top(*r, px(272));
    draw_typography_card(typo, 5);
    return typo.y + typo.h;
}

stat_tile :: (inner: Rect, label: string, value: string, sub: string, history: [] float, scale_ms: float, color: Color) {
    r := inner;
    draw_text_in_rect(fonts.regular, px(13), cut_top(*r, px(18)), label, theme.text_secondary);
    cut_top(*r, px(6));
    value_row := cut_top(*r, px(40));
    value_w := draw_text_in_rect(fonts.light, px(theme.font_size_display), value_row, value, theme.text);
    side_x := max(inner.x + value_w + px(24), inner.x + inner.w * 0.55);
    side_w := inner.x + inner.w - side_x;
    cut_top(*r, px(4));
    draw_text_in_rect(fonts.regular, px(12), cut_top(*r, px(18)), sub, theme.text_muted);

    if side_w < px(60) return;
    if history.count {
        // Recent frames as bars, newest on the right.
        graph_w := min(side_w, px(180));
        graph := rect(inner.x + inner.w - graph_w, inner.y, graph_w, px(44));
        n := 30;
        bw := graph.w / n;
        peak := scale_ms;
        for 0..n - 1 peak = max(peak, history[(app.history_at - n + it + HISTORY) % HISTORY]);
        for 0..n - 1 {
            v := history[(app.history_at - n + it + HISTORY) % HISTORY];
            h := max(graph.h * (v / peak), px(2));
            bar := rect(graph.x + it * bw, graph.y + graph.h - h, max(bw - px(2), 1.0), h);
            draw_rect(bar, color_with_alpha(color, 0.35 + 0.65 * (it / cast(float) n)), px(1.5));
        }
    } else {
        // A meter: instances against a budget of 10k.
        meter := rect(side_x, inner.y + px(18), side_w, px(8));
        draw_rect(meter, theme.surface_hover, px(4));
        fill := meter;
        fill.w = max(meter.w * clamp(renderer_stats.instances / 2000.0, 0.0, 1.0), px(8));
        draw_rect_gradient(fill, color, color_lerp(color, rgb(0x000000), 0.2), px(4));
    }
}

draw_controls_card :: (r: Rect, index: int) {
    inner := card(r, "Controls", index);
    row_h := px(34);
    ui_toggle("V-sync", cut_top(*inner, row_h), *renderer_settings.vsync);
    cut_top(*inner, px(6));
    ui_toggle("Continuous rendering", cut_top(*inner, row_h), *app.continuous_rendering);
    cut_top(*inner, px(12));
    ui_slider("Animation speed", cut_top(*inner, px(52)), *app.animation_speed, 0.25, 3, tprint("%x", formatFloat(app.animation_speed, trailing_width = 2, zero_removal = .NO)));

    buttons := cut_bottom(*inner, px(theme.control_height));
    if ui_button("Play", cut_left(*buttons, button_width("Play")), .PRIMARY) {
        app.demo_playing = true;
        randomize_demo_bars();
    }
    cut_left(*buttons, px(10));
    if ui_button("Reset", cut_left(*buttons, button_width("Reset")), .SECONDARY) {
        app.demo_playing = false;
        app.demo_time = 0;
        app.demo_progress_target = 0;
        for * app.demo_bars it.target = 0.08;
    }
    cut_left(*buttons, px(6));
    pause_label := ifx app.demo_playing then "Pause" else "Resume";
    if ui_button(pause_label, cut_left(*buttons, button_width(pause_label)), .GHOST) {
        app.demo_playing = !app.demo_playing;
    }
    card_end();
}

button_width :: (label: string) -> float {
    return max(measure_text(fonts.semibold, px(theme.font_size_body), label) + px(36), px(72));
}

randomize_demo_bars :: () {
    for * app.demo_bars {
        app.demo_seed = app.demo_seed * 1664525 + 1013904223;
        it.target = 0.25 + 0.75 * ((app.demo_seed >> 8) & 0xFFFF) / 65535.0;
    }
    app.demo_progress_target = 0.25 + 0.75 * ((app.demo_seed >> 4) & 0xFF) / 255.0;
}

draw_animation_card :: (r: Rect, index: int) {
    inner := card(r, "Animation", index);
    dt := ui.dt * app.animation_speed;
    if app.demo_playing {
        app.demo_time += dt;
        ui.animating = true;
    }

    // Springy bars.
    bars := cut_top(*inner, px(120));
    n := app.demo_bars.count;
    gap := px(12);
    bw := (bars.w - gap * (n - 1)) / n;
    for * app.demo_bars {
        it.target = clamp(it.target, 0, 1);
        if spring_update(it, dt, 160, 0.42) ui.animating = true;
        h := max(bars.h * clamp(it.value, 0, 1.2), px(6));
        bar := rect(bars.x + it_index * (bw + gap), bars.y + bars.h - h, bw, h);
        top := color_lerp(theme.accent_top, rgb(0xA78BFA), it_index / cast(float) (n - 1));
        draw_rect_gradient(snap(bar), top, color_with_alpha(top, 0.35), px(6));
    }

    cut_top(*inner, px(22));
    // Progress, eased toward its target.
    progress_row := cut_top(*inner, px(18));
    app.demo_progress = damp(app.demo_progress, app.demo_progress_target, 3, dt);
    if abs(app.demo_progress - app.demo_progress_target) > 0.0005 ui.animating = true;
    draw_text_in_rect(fonts.regular, px(13), progress_row, "Upload progress", theme.text_secondary);
    draw_text_in_rect(fonts.semibold, px(13), progress_row, tprint("%%", cast(int) (app.demo_progress * 100 + 0.5), "%"), theme.text, .RIGHT);
    cut_top(*inner, px(8));
    track := snap(cut_top(*inner, px(8)));
    draw_rect(track, theme.surface_hover, px(4));
    fill := track;
    fill.w = track.w * app.demo_progress;
    draw_rect_gradient(fill, theme.accent_top, theme.accent_bottom, px(4));

    cut_top(*inner, px(24));
    // A pill sweeping back and forth on an eased curve.
    lane := snap(cut_top(*inner, px(28)));
    draw_rect(lane, color_with_alpha(theme.surface_hover, 0.6), lane.h * 0.5);
    phase := app.demo_time * 0.6;
    t := phase - floor(phase);
    t = ifx t < 0.5 then ease_in_out_cubic(t * 2) else ease_in_out_cubic(2 - t * 2);
    pill_w := px(64);
    pill := rect(lane.x + px(3) + (lane.w - pill_w - px(6)) * t, lane.y + px(3), pill_w, lane.h - px(6));
    draw_shadow(pill, pill.h * 0.5, px(10), color_with_alpha(theme.accent, 0.5), 0, px(2));
    draw_rect_gradient(pill, theme.accent_top, theme.accent_bottom, pill.h * 0.5);
    card_end();
}

draw_typography_card :: (r: Rect, index: int) {
    inner := card(r, "Typography", index);
    SAMPLE :: "The quick brown fox jumps over the lazy dog";
    sizes := float.[12, 14, 16, 20, 28];
    y := inner.y;
    for sizes {
        m := font_metrics(fonts.regular, px(it));
        y += m.line_height + px(4);
        draw_text(fonts.regular, px(12), inner.x, y, tprint("%px", cast(int) it), theme.text_muted);
        font := ifx it >= 20 then fonts.semibold else fonts.regular;
        draw_text(font, px(it), inner.x + px(56), y, SAMPLE, ifx it >= 20 then theme.text else theme.text_secondary);
    }
    y += px(22);
    draw_text(fonts.regular, px(14), inner.x, y, tprint("FreeType rasterizes each glyph at its exact pixel size (here at %% scale), cached in a % x % atlas.", cast(int) (ui.scale * 100 + 0.5), "%", glyph_atlas.size, glyph_atlas.size), theme.text_muted);
    card_end();
}

//
// Other pages.
//

List_Item :: struct { title: string; detail: string; status: string; color: Color; }

draw_projects :: (body: Rect) -> float {
    items := List_Item.[
        .{"Renderer",          "Direct3D 11 backend, flip model swap chain", "Shipped",     #run rgb(0x3DD68C)},
        .{"Text",              "FreeType glyph cache with subpixel positioning", "Shipped", #run rgb(0x3DD68C)},
        .{"macOS platform",    "Cocoa window and Metal backend",             "Planned",     #run rgb(0x7E93FF)},
        .{"Linux platform",    "Wayland/X11 window and Vulkan backend",      "Planned",     #run rgb(0x7E93FF)},
        .{"Text shaping",      "HarfBuzz for ligatures and complex scripts", "Exploring",   #run rgb(0xF5B14C)},
        .{"Layout",            "Flexible rows and columns on top of rect cutting", "Exploring", #run rgb(0xF5B14C)},
    ];
    return draw_list(body, "Projects", items);
}

draw_activity :: (body: Rect) -> float {
    items := List_Item.[
        .{"Atlas grew",          "Glyph atlas doubled to keep every glyph resident", "2m ago",  #run rgb(0xA0A7B4)},
        .{"Window resized",      "Swap chain buffers resized in place",            "5m ago",  #run rgb(0xA0A7B4)},
        .{"DPI changed",         "Moved to a 150% monitor; glyphs re-rasterized",   "12m ago", #run rgb(0xA0A7B4)},
        .{"Build succeeded",     "Shaders compiled to bytecode at build time",      "1h ago",  #run rgb(0x3DD68C)},
        .{"Device created",      "Hardware adapter, feature level 11_1",            "1h ago",  #run rgb(0xA0A7B4)},
    ];
    return draw_list(body, "Recent", items);
}

draw_list :: (body: Rect, title: string, items: [] List_Item) -> float {
    row_h := px(60);
    r := body;
    panel := cut_top(*r, px(22 + 18 + 14 + 18) + row_h * items.count);
    inner := card(panel, title, 0);
    for items {
        row := cut_top(*inner, row_h);
        id := ui_id(title, it_index);
        w := ui_widget(id);
        io := ui_interact(id, row);
        ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 18);
        if w.hover > 0 draw_rect(snap(rect_inset_xy(row, -px(10), px(3))), color_with_alpha(theme.surface_hover, w.hover * 0.7), px(theme.radius_control));
        if it_index > 0 ui_divider(row.x, row.y, row.w);

        text_area := rect_inset_xy(row, 0, px(10));
        draw_text_in_rect(fonts.semibold, px(14), cut_top(*text_area, text_area.h * 0.5), it.title, theme.text);
        draw_text_in_rect(fonts.regular, px(13), text_area, it.detail, theme.text_secondary);

        // Status pill.
        label_w := measure_text(fonts.semibold, px(12), it.status);
        pill := snap(rect(row.x + row.w - label_w - px(24), row.y + (row.h - px(24)) * 0.5, label_w + px(24), px(24)));
        draw_rect(pill, color_with_alpha(it.color, 0.14), pill.h * 0.5);
        draw_text_in_rect(fonts.semibold, px(12), pill, it.status, it.color, .CENTER);
    }
    card_end();
    return panel.y + panel.h;
}

draw_settings :: (body: Rect) -> float {
    r := body;
    panel := cut_top(*r, px(300));
    left := cut_left(*panel, min(panel.w, px(520)));
    draw_controls_card(left, 0);
    return panel.y + panel.h;
}

//
// Status bar.
//

draw_status_bar :: (area: Rect) {
    draw_rect(area, theme.sidebar);
    draw_rect(snap(rect(area.x, area.y, area.w, px(1))), theme.divider);
    r := rect_inset_xy(area, px(16), 0);
    size := px(12);

    active := app.was_animating || app.continuous_rendering;
    dot_color := ifx active then theme.success else theme.text_muted;
    draw_circle(r.x + px(4), r.y + r.h * 0.5, px(3.5), dot_color);
    cut_left(*r, px(16));
    left := ifx active then "Rendering" else "Idle, waiting for input";
    w := draw_text_in_rect(fonts.regular, size, r, left, theme.text_secondary);
    cut_left(*r, w + px(24));
    mode := ifx APP_RELEASE then "release" else "debug";
    draw_text_in_rect(fonts.regular, size, r, tprint("Direct3D 11  ·  % draw call  ·  % instances  ·  frame %  ·  %", renderer_stats.draw_calls, renderer_stats.instances, clock.frame_count, mode), theme.text_muted);

    right := tprint("V: vsync %  ·  C: continuous %  ·  % Hz  ·  %% scale", ifx renderer_settings.vsync then "on" else "off", ifx app.continuous_rendering then "on" else "off", cast(int) (platform.refresh_hz + 0.5), cast(int) (ui.scale * 100 + 0.5), "%");
    draw_text_in_rect(fonts.regular, size, r, right, theme.text_muted, .RIGHT);
}
