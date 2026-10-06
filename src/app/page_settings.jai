// Settings: connection, data, display, diagnostics, about, keys.

Settings_State :: struct {
    new_token: Text_Buffer;
    animation_speed: float = 1;
}

draw_settings_page :: (r_in: Rect) {
    st := *app.settings_page;
    r := r_in;
    cut_top(*r, px(10));
    gap := px(8);
    left := cut_left(*r, (r.w - gap) * 0.5);
    cut_left(*r, gap);
    right := r;

    connection_r := cut_top(*left, ifx sync.auth_failed then px(236) else px(176));
    cut_top(*left, gap);
    data_r := cut_top(*left, px(352));
    cut_top(*left, gap);
    draw_connection_panel(appear_begin(connection_r, 0), st);
    appear_end();
    draw_data_panel(appear_begin(data_r, 1));
    appear_end();
    draw_keys_panel(appear_begin(left, 2));
    appear_end();

    display_r := cut_top(*right, px(208));
    cut_top(*right, gap);
    // On a short window About sets its logo beside the name, so Diagnostics keeps room for its
    // readouts; shorter still, Diagnostics gives way and About takes the column.
    disclaimer := disclaimer_lines(right.w);
    stacked_h := about_panel_height(disclaimer.count, false);
    room := right.h - gap - px(DIAGNOSTICS_MIN_HEIGHT);
    show_diagnostics := room >= about_panel_height(disclaimer.count, true);
    about_compact := ifx show_diagnostics then room < stacked_h else right.h < stacked_h;
    about_r := right;
    if show_diagnostics {
        about_r = cut_bottom(*right, about_panel_height(disclaimer.count, about_compact));
        cut_bottom(*right, gap);
    }
    draw_display_panel(appear_begin(display_r, 3), st);
    appear_end();
    if show_diagnostics {
        draw_diagnostics_panel(appear_begin(right, 4));
        appear_end();
    }
    draw_about_panel(appear_begin(about_r, 5), about_compact, disclaimer);
    appear_end();
}

#scope_file

ROW :: 30.0;

draw_connection_panel :: (r: Rect, st: *Settings_State) {
    content, _ := panel_begin(r, "Connection");
    inner := rect_inset_xy(content, px(16), px(10));
    status_r := cut_top(*inner, px(24));
    dot := ifx sync.auth_failed then theme.danger else ifx sync.phase == .READY || sync.phase == .LOADING then theme.positive else theme.text_faint;
    draw_circle(status_r.x + px(4), status_r.y + status_r.h * 0.5, px(4), dot);
    status := ifx sync.demo then "Sample data: an offline simulation of the Up API" else ifx sync.auth_failed then "Up rejected the access token (401)" else "Connected to api.up.com.au";
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), rect(status_r.x + px(16), status_r.y, status_r.w, status_r.h), status, theme.text);
    cut_top(*inner, px(4));
    if !sync.demo {
        draw_field(cut_top(*inner, px(22)), "Access token", mask_token(sync.token), true);
        stored := file_exists(token_path());
        draw_field(cut_top(*inner, px(22)), "Stored", ifx stored then "Encrypted for this Windows user (DPAPI)" else "Not stored: this session only");
    } else {
        draw_field(cut_top(*inner, px(22)), "Data", "Generated on this PC; nothing is sent anywhere");
        draw_field(cut_top(*inner, px(22)), "Writes", "Category, tag and webhook changes apply to the simulation");
    }

    if sync.auth_failed {
        cut_top(*inner, px(8));
        row := cut_top(*inner, px(30));
        go := cut_right(*row, px(100));
        cut_right(*row, px(8));
        _, submitted := ui_text_input("new-token##settings", row, *st.new_token, "Paste a new personal access token", .MONO | .PASSWORD);
        token := trim(buffer_string(*st.new_token));
        if (ui_button("Reconnect##settings", go, .PRIMARY, enabled = token.count > 0) || (submitted && token.count)) {
            sync_start(token, false);
            st.new_token.count = 0;
        }
        cut_top(*inner, px(6));
    }

    buttons := cut_bottom(*inner, px(28));
    if !sync.demo {
        if ui_button("Test connection", cut_left(*buttons, px(130)), .SECONDARY, .LIGHTNING, enabled = sync.phase == .READY) {
            api_submit(.PING, "GET", "/util/ping", generation = sync.generation, arg = "test", urgent = true);
        }
        cut_left(*buttons, px(8));
        if ui_button("Disconnect and forget token", cut_left(*buttons, px(200)), .DANGER, .LOCK) {
            ask_confirm(.DISCONNECT, "Disconnect from Up?", "Uppies will forget the saved access token and everything it has loaded. You can connect again with the same token.", "Disconnect");
        }
    } else {
        if ui_button("Connect a real account", cut_left(*buttons, px(178)), .PRIMARY, .PLUG) {
            settings.sample_data = false;
            settings_save();
            sync_disconnect();
        }
    }
}

draw_data_panel :: (r: Rect) {
    content, _ := panel_begin(r, "Data");
    inner := rect_inset_xy(content, px(16), px(10));

    row := cut_top(*inner, px(ROW));
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), row, "History to load", theme.text);
    history := cast(int) settings.history;
    if ui_dropdown_strings("history##settings", cut_right(*row, px(150)), HISTORY_LABELS, *history) {
        settings.history = cast(History_Depth) history;
        settings_save();
        app_toast(.INFO, "Takes effect the next time Uppies opens, or when you delete local data.");
    }
    cut_top(*inner, px(4));
    row = cut_top(*inner, px(ROW));
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), row, "Refresh automatically", theme.text);
    auto := settings.auto_refresh;
    if ui_segmented("auto-refresh##settings", cut_right(*row, ui_segmented_width(AUTO_REFRESH_LABELS)), AUTO_REFRESH_LABELS, *auto) {
        settings.auto_refresh = auto;
        minutes := AUTO_REFRESH_MINUTES[auto];
        sync.next_auto = ifx minutes > 0 then ui.time + minutes * 60 else 0;
        settings_save();
    }
    cut_top(*inner, px(6));
    if ui_toggle("Leave out transfers between my accounts", cut_top(*inner, px(40)), *settings.exclude_transfers, "Moving money to a saver isn't income or spending. Affects every total.") settings_save();
    if ui_toggle("Keep an encrypted copy on this PC", cut_top(*inner, px(40)), *settings.store_locally, "Opens instantly and downloads only what changed. Only your Windows account, with this token, can read it.") {
        settings_save();
        if settings.store_locally {
            local_data_save();
            app_toast(.SUCCESS, "Your data will be kept on this PC, encrypted.");
        } else {
            local_data_delete();
            app_toast(.INFO, "Local copy deleted. Uppies will download everything each time it opens.");
        }
    }
    cut_top(*inner, px(8));
    ui_divider(inner.x, inner.y, inner.w, theme.divider);
    cut_top(*inner, px(8));

    oldest := ifx store.transactions.count then format_date(store.transactions[store.transactions.count - 1].day) else "—";
    draw_field(cut_top(*inner, px(22)), "Loaded", tprint("% transactions since %", format_grouped(store.transactions.count), oldest));
    last := ifx sync.last_sync_utc then tprint("% (%)", format_time_seconds(Timestamp.{sync.last_sync_utc, app.now.offset_minutes}), format_relative(app.now.utc_seconds - sync.last_sync_utc)) else "Not yet";
    draw_field(cut_top(*inner, px(22)), "Last sync", last);

    // What's on disk.
    stored := "";
    stored_color: Color = 0;
    if sync.demo && !local_data.cache_demo {
        stored = "Sample data isn't stored";
    } else if !settings.store_locally {
        stored = "Nothing: downloaded fresh each time";
    } else {
        size, saved_utc, failed := store_file_info();
        if failed {
            stored = "Couldn't save the latest changes; will try again";
            stored_color = theme.held;
        } else if size {
            when := ifx saved_utc then tprint(" · saved %", format_relative(app.now.utc_seconds - saved_utc)) else "";
            stored = tprint("% · AES-256 encrypted%", format_bytes(size), when);
        } else {
            stored = "Not saved yet";
        }
    }
    draw_field(cut_top(*inner, px(22)), "On this PC", stored, false, stored_color);

    // Up has no feed of changes: older edits are found by reading everything again.
    check := "";
    if sync.refreshing && sync.refresh_kind == .FULL {
        check = "Checking every transaction now…";
    } else if sync.last_full_check_utc {
        due := sync_full_check_due_in();
        next := ifx due <= 0 then "due now" else tprint("next in %", format_span(due));
        check = tprint("Weekly · last %, %", format_relative(app.now.utc_seconds - sync.last_full_check_utc), next);
    } else {
        check = "Weekly · after the first full download";
    }
    draw_field(cut_top(*inner, px(22)), "Full check", check);

    buttons := cut_bottom(*inner, px(28));
    idle := sync.phase == .READY && !sync.refreshing;
    if ui_button("Refresh now", cut_left(*buttons, ui_button_width("Refresh now", .REFRESH)), .SECONDARY, .REFRESH, enabled = idle && !sync.from_saved) sync_refresh(true);
    cut_left(*buttons, px(8));
    if ui_button("Check all now", cut_left(*buttons, ui_button_width("Check all now", .SYNC)), .SECONDARY, .SYNC, enabled = idle && !sync.from_saved && sync.history_complete) sync_full_check();
    cut_left(*buttons, px(8));
    if ui_button("Delete local data", cut_left(*buttons, ui_button_width("Delete local data", .DELETE)), .DANGER, .DELETE, enabled = sync.phase == .READY || sync.phase == .LOADING) {
        ask_confirm(.DELETE_LOCAL_DATA, "Delete local data?",
            tprint("Uppies will delete the copy of your data stored on this PC and download your accounts and % from Up again. Your access token and settings are kept.", to_lower_temp(HISTORY_LABELS[settings.history])),
            "Delete and download again");
    }
}

draw_display_panel :: (r: Rect, st: *Settings_State) {
    content, _ := panel_begin(r, "Display");
    inner := rect_inset_xy(content, px(16), px(8));
    if ui_toggle("Reduce motion", cut_top(*inner, px(40)), *settings.reduce_motion, "Changes happen at once instead of animating.") {
        ui.motion = ifx settings.reduce_motion then 0.0 else st.animation_speed;
        settings_save();
    }
    if ui_toggle("V-sync", cut_top(*inner, px(40)), *settings.vsync, "Off renders as fast as possible while animating (tearing allowed).") {
        renderer_settings.vsync = settings.vsync;
        settings_save();
    }
    ui_toggle("Render continuously", cut_top(*inner, px(40)), *app.continuous_rendering, "For benchmarking: otherwise frames are drawn only when something changes.");
    cut_top(*inner, px(4));
    if !settings.reduce_motion {
        if ui_slider("Animation speed", cut_top(*inner, px(44)), *st.animation_speed, 0.25, 2, tprint("%x", formatFloat(st.animation_speed, trailing_width = 2, zero_removal = .NO))) {
            ui.motion = st.animation_speed;
        }
    }
}

draw_diagnostics_panel :: (r: Rect) {
    content, _ := panel_begin(r, "Diagnostics");
    inner := rect_inset_xy(content, px(16), px(10));
    half := (inner.w - px(16)) * 0.5;
    left := rect(inner.x, inner.y, half, inner.h);
    right := rect(inner.x + half + px(16), inner.y, half, inner.h);

    draw_caps(cut_top(*left, px(18)), "Renderer", theme.text_muted);
    animating := app.was_animating || app.continuous_rendering;
    draw_field(cut_top(*left, px(22)), "Frame time", tprint("% ms CPU", formatFloat(app.shown_cpu_ms, trailing_width = 2, zero_removal = .NO)), true);
    draw_field(cut_top(*left, px(22)), "Frame rate", ifx animating then tprint("% fps", cast(int) (app.shown_fps + 0.5)) else "Idle: 0 fps", true);
    draw_field(cut_top(*left, px(22)), "Display", tprint("% Hz · vsync %", cast(int) (platform.refresh_hz + 0.5), ifx renderer_settings.vsync then "on" else "off"), true);
    draw_field(cut_top(*left, px(22)), "Draw calls", tprint("% · % instances", renderer_stats.draw_calls, format_grouped(renderer_stats.instances)), true);
    draw_field(cut_top(*left, px(22)), "Uploaded", tprint("% KB per frame", formatFloat(renderer_stats.upload_bytes / 1024.0, trailing_width = 1, zero_removal = .NO)), true);
    draw_field(cut_top(*left, px(22)), "Glyph atlas", tprint("% × % · % scale", glyph_atlas.size, glyph_atlas.size, format_percent(ui.scale, 0)), true);

    draw_caps(cut_top(*right, px(18)), "Up API", theme.text_muted);
    avg := ifx api_stats.requests then api_stats.total_ms / api_stats.requests else 0;
    draw_field(cut_top(*right, px(22)), "Requests", tprint("% · % failed", format_grouped(api_stats.requests), api_stats.failures), true);
    draw_field(cut_top(*right, px(22)), "Latency", tprint("% ms last · % ms avg", cast(int) (api_stats.last_ms + 0.5), cast(int) (avg + 0.5)), true);
    draw_field(cut_top(*right, px(22)), "In flight", tprint("%", api_in_flight()), true);
    draw_field(cut_top(*right, px(22)), "Last error", ifx api_stats.last_error.count then api_stats.last_error else "None", false, ifx api_stats.last_error.count then theme.held else 0);
    draw_field(cut_top(*right, px(22)), "Data folder", platform_app_data_dir(), true);
    if ui_link("Open data folder##settings", cut_top(*right, px(22))) platform_open_url(platform_app_data_dir());

    // Frame history: CPU time to build and submit each of the last frames.
    // Idle frames aren't drawn at all, so a quiet UI shows a short history.
    history := inner;
    cut_top(*history, max(left.y, right.y) - inner.y + px(14));
    if history.h < px(90) return;
    draw_caps(cut_top(*history, px(18)), "CPU per frame · last 90 frames", theme.text_muted);
    graph := rect(history.x + px(40), history.y + px(4), history.w - px(40), min(history.h - px(10), px(120)));
    n := app.cpu_ms.count;
    peak: float = 2;
    for app.cpu_ms peak = max(peak, it);
    peak = ceil(peak);
    ui_divider(graph.x, graph.y + graph.h, graph.w, theme.border_strong);
    for tick: 1..cast(int) peak {
        y := graph.y + graph.h - graph.h * tick / peak;
        if peak > 6 && tick % 2 != 0 continue;
        ui_divider(graph.x, y, graph.w, theme.grid);
        draw_text_in_rect(fonts.mono, px(theme.font_size_small), rect(history.x, y - px(8), px(34), px(16)), tprint("% ms", tick), theme.text_muted, .RIGHT);
    }
    bw := graph.w / n;
    for i: 0..n - 1 {
        v := app.cpu_ms[(app.history_at + i) % n];
        h := max(graph.h * v / peak, px(1));
        draw_rect(rect(graph.x + i * bw + px(1), graph.y + graph.h - h, max(bw - px(2), 1.0), h), color_with_alpha(theme.chart_line, 0.35 + 0.65 * i / cast(float) n), px(1));
    }
}

DISCLAIMER :: "Uppies is an independent, unofficial app. It is not affiliated with, endorsed by or sponsored by Up or Bendigo and Adelaide Bank Limited. \"Up\" is a trademark of its owner and is used here only to say which bank Uppies works with. Uppies is provided as is, without warranty of any kind, and nothing in it is financial advice.";
DISCLAIMER_LINE :: 17.0;

disclaimer_lines :: (panel_w: float) -> [] string {
    return wrap_lines(fonts.regular, px(theme.font_size_label), DISCLAIMER, panel_w - px(32));
}

DIAGNOSTICS_MIN_HEIGHT :: 214.0;   // Header and the six readout rows.
ABOUT_MARK :: 44.0;
ABOUT_TITLE :: 20.0;
ABOUT_HERO_STACKED :: 16 + ABOUT_MARK + 10 + 26 + 20;   // Logo above the name and byline.
ABOUT_HERO_COMPACT :: 16 + ABOUT_MARK;                  // Logo beside them.

// The hero, the links, a divider, the disclaimer's lines, and the copyright.
about_panel_height :: (line_count: int, compact: bool) -> float {
    hero := ifx compact then ABOUT_HERO_COMPACT else ABOUT_HERO_STACKED;
    return px(theme.panel_header_height) + px(hero) + px(12 + 22 + 14 + 13) + line_count * px(DISCLAIMER_LINE) + px(6 + 18 + 12);
}

draw_about_panel :: (r: Rect, compact: bool, disclaimer: [] string) {
    content, _ := panel_begin(r, "About");
    inner := rect_inset_xy(content, px(16), 0);
    cut_top(*inner, px(16) + max(r.h - about_panel_height(disclaimer.count, compact), 0) * 0.5);   // Centered when given more room than it needs.
    cx := inner.x + inner.w * 0.5;

    title_size := px(ABOUT_TITLE);
    byline_size := px(theme.font_size_body);
    BYLINE :: "Made by Ruben Bala";
    if compact {
        hero := cut_top(*inner, px(ABOUT_MARK));
        text_w := max(measure_text(fonts.semibold, title_size, "Uppies"), measure_text(fonts.regular, byline_size, BYLINE));
        x := cx - (px(ABOUT_MARK) + px(14) + text_w) * 0.5;
        draw_brand_mark(snap(rect(x, hero.y, px(ABOUT_MARK), px(ABOUT_MARK))));
        x += px(ABOUT_MARK) + px(14);
        draw_text_in_rect(fonts.semibold, title_size, rect(x, hero.y - px(1), text_w, px(26)), "Uppies", theme.text);
        draw_text_in_rect(fonts.regular, byline_size, rect(x, hero.y + px(24), text_w, px(20)), BYLINE, theme.text_secondary);
    } else {
        mark := cut_top(*inner, px(ABOUT_MARK));
        draw_brand_mark(snap(rect(cx - px(ABOUT_MARK) * 0.5, mark.y, px(ABOUT_MARK), px(ABOUT_MARK))));
        cut_top(*inner, px(10));
        draw_text_in_rect(fonts.semibold, title_size, cut_top(*inner, px(26)), "Uppies", theme.text, .CENTER);
        draw_text_in_rect(fonts.regular, byline_size, cut_top(*inner, px(20)), BYLINE, theme.text_secondary, .CENTER);
    }

    // Links, centered as a group: an icon, then the link, with a dot between.
    cut_top(*inner, px(12));
    links := cut_top(*inner, px(22));
    LINKS :: struct { icon: Icon; label: string; url: string; }.[
        .{.GLOBE, "ruben.net.au##about", "https://ruben.net.au"},
        .{.LINK,  "github.com/rubenbala/uppies##about", "https://github.com/rubenbala/uppies"},
    ];
    link_size := px(theme.font_size_label);
    icon_w := px(12) + px(6);
    sep_w := px(28);
    total := sep_w * (LINKS.count - 1);
    for LINKS total += icon_w + measure_text(fonts.regular, link_size, display_text(it.label));
    x := cx - total * 0.5;
    for LINKS {
        if it_index > 0 {
            draw_circle(x + sep_w * 0.5, links.y + links.h * 0.5, px(1.5), theme.text_faint);
            x += sep_w;
        }
        draw_icon(it.icon, x + px(6), links.y + links.h * 0.5, px(12), theme.text_muted);
        x += icon_w;
        w := measure_text(fonts.regular, link_size, display_text(it.label));
        if ui_link(it.label, rect(x, links.y, w, links.h)) platform_open_url(it.url);
        x += w;
    }

    cut_top(*inner, px(14));
    ui_divider(inner.x, inner.y, inner.w, theme.divider);
    cut_top(*inner, px(13));
    for disclaimer draw_text_in_rect(fonts.regular, px(theme.font_size_label), cut_top(*inner, px(DISCLAIMER_LINE)), it, theme.text_muted, .CENTER);
    cut_top(*inner, px(6));
    draw_text_in_rect(fonts.regular, px(theme.font_size_small), cut_top(*inner, px(18)), "© 2026 Ruben Bala", theme.text_faint, .CENTER);
}

draw_keys_panel :: (r: Rect) {
    content, _ := panel_begin(r, "Keyboard");
    inner := rect_inset_xy(content, px(16), px(8));
    KEYS :: string.[
        "Ctrl+1 – Ctrl+7", "Switch page",
        "Ctrl+Tab",            "Next page (Shift: previous)",
        "/  or  Ctrl+F",       "Search transactions",
        "F5  or  Ctrl+R",      "Refresh from Up",
        "↑ ↓  PgUp PgDn  Home End", "Move through the focused table",
        "Esc",                 "Close a menu, clear a search, close the inspector",
        "Tab / Shift+Tab",     "Move keyboard focus; Enter or Space activates",
    ];
    for i: 0..KEYS.count / 2 - 1 {
        row := cut_top(*inner, px(24));
        if row.h < px(20) break;
        draw_text_in_rect(fonts.mono, px(theme.font_size_label), rect(row.x, row.y, px(200), row.h), KEYS[i * 2], theme.text);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(row.x + px(200), row.y, row.w - px(200), row.h), KEYS[i * 2 + 1], theme.text_secondary);
    }
}
