// Settings: connection, data, display, diagnostics, keys.

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
    data_r := cut_top(*left, px(262));
    cut_top(*left, gap);
    draw_connection_panel(appear_begin(connection_r, 0), st);
    appear_end();
    draw_data_panel(appear_begin(data_r, 1));
    appear_end();
    draw_keys_panel(appear_begin(left, 2));
    appear_end();

    display_r := cut_top(*right, px(208));
    cut_top(*right, gap);
    draw_display_panel(appear_begin(display_r, 3), st);
    appear_end();
    draw_diagnostics_panel(appear_begin(right, 4));
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
        app_toast(.INFO, "Applies the next time everything is reloaded.");
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
    cut_top(*inner, px(8));
    ui_divider(inner.x, inner.y, inner.w, theme.divider);
    cut_top(*inner, px(8));

    oldest := ifx store.transactions.count then format_date(store.transactions[store.transactions.count - 1].day) else "—";
    draw_field(cut_top(*inner, px(22)), "Loaded", tprint("% transactions since %", format_grouped(store.transactions.count), oldest));
    last := ifx sync.last_sync_utc then tprint("% (%)", format_time_seconds(Timestamp.{sync.last_sync_utc, app.now.offset_minutes}), format_relative(app.now.utc_seconds - sync.last_sync_utc)) else "Not yet";
    draw_field(cut_top(*inner, px(22)), "Last sync", last);

    buttons := cut_bottom(*inner, px(28));
    if ui_button("Refresh now", cut_left(*buttons, px(112)), .SECONDARY, .REFRESH, enabled = sync.phase == .READY && !sync.refreshing) sync_refresh(true);
    cut_left(*buttons, px(8));
    if ui_button("Reload everything", cut_left(*buttons, px(146)), .SECONDARY, .SYNC, enabled = sync.phase == .READY) {
        ask_confirm(.RELOAD, "Reload everything?", tprint("Uppies will drop what it has loaded and fetch your accounts and % again. Large histories take a little while.", to_lower_temp(HISTORY_LABELS[settings.history])), "Reload");
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
