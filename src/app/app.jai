// Uppies: a desktop console for an Up bank account, on the Up API.
//
// The window is a top bar (brand, the pages as tabs, sync state), a page,
// and a status bar. Pages are built around the questions they answer:
//
//   Overview      Where do I stand, and what changed recently?
//   Transactions  Find, inspect and fix (category, tags) individual transactions.
//   Accounts      How is each balance moving, month by month?
//   Spending      Where does the money go, and how does it compare?
//   Tags          What did each tagged project or trip cost?
//   Webhooks      Are my webhooks configured and delivering?
//   Settings      Connection, data, display, diagnostics.

Page :: enum u8 { OVERVIEW; TRANSACTIONS; ACCOUNTS; SPENDING; TAGS; WEBHOOKS; SETTINGS; }

PAGE_TITLES :: string.["Overview", "Transactions", "Accounts", "Spending", "Tags", "Webhooks", "Settings"];
PAGE_COUNT  :: 7;

Toast_Kind :: enum u8 { INFO; SUCCESS; ERROR; }

Toast :: struct {
    kind: Toast_Kind;
    text: string;
    born: float64;
    life: float;
    t:    float;
    leaving: bool;
}

Confirm_Kind :: enum u8 { NONE; DELETE_WEBHOOK; DISCONNECT; DELETE_LOCAL_DATA; }

Confirm :: struct {
    open:    bool;
    t:       float;
    title:   string;
    detail:  string;
    action:  string;
    ref:     string;
    kind:    Confirm_Kind;
}

App :: struct {
    page: Page;
    previous_page: Page;
    page_t: float = 1;
    page_age: float;           // Seconds since the page appeared.
    tab_x: Spring;
    tab_w: Spring;
    tabs_ready: bool;
    console_t: float;          // Connect screen -> console transition.
    keep_page: bool;           // A page was asked for at startup: stay on it.

    now: Local_Time;
    today: s64;

    toasts: [..] Toast;
    confirm: Confirm;

    connect: Connect_State;
    overview: Overview_State;
    txn: Transactions_State;
    accounts: Accounts_State;
    spending: Spending_State;
    tags: Tags_State;
    webhooks: Webhooks_State;
    settings_page: Settings_State;

    // Rendering diagnostics (Settings).
    continuous_rendering: bool;
    max_fps: float;
    cpu_ms:      [90] float;
    interval_ms: [90] float;
    history_at:  int;
    shown_cpu_ms: float;
    shown_fps:    float;
    was_animating: bool;
}

app: App;

app_init :: (start_demo := false) {
    settings_load();
    renderer_settings.vsync = settings.vsync;
    ui.motion = ifx settings.reduce_motion then 0.0 else 1.0;
    api_init();
    demo_init();

    // A saved token connects straight away. Without one, the connect screen
    // offers a token or sample data; only -demo starts on sample data.
    token, ok := token_load();
    if start_demo {
        sync_start("", true);
        app.connect.auto_connecting = true;
    } else if ok && token.count {
        buffer_set(*app.connect.token, token);
        sync_start(token, false);
        app.connect.auto_connecting = true;
    }
    // Opened on saved data: the console is there from the first frame, no
    // fade in from the connect screen.
    if sync.from_saved app.console_t = 1;
}

app_frame :: () {
    app.now = platform_local_time();
    app.today = floor_div(app.now.utc_seconds + app.now.offset_minutes * 60, SECONDS_PER_DAY);
    record_timings();
    sync_update();
    local_data_update();
    analytics_update(app.today);
    // Relative times ("3m ago") stay current: a frame a minute is enough.
    ui_wake_at(ui.time + 60 - fmod_cycling(cast(float) app.now.utc_seconds, 60.0));

    full := rect(0, 0, xx platform.width, xx platform.height);
    draw_rect(full, theme.background);

    in_console := sync.phase == .LOADING || sync.phase == .READY;
    ui_animate(*app.console_t, ifx in_console then 1.0 else 0.0, 7);

    if app.console_t < 0.999 {
        push_opacity(1 - app.console_t);
        draw_connect_screen(full);
        pop_opacity();
    }
    if app.console_t > 0.001 {
        push_opacity(app.console_t);
        draw_console(full);
        pop_opacity();
    }

    draw_toasts(full);
    draw_confirm();
    if in_console handle_hotkeys();
    app.was_animating = ui.animating;
}

app_toast :: (kind: Toast_Kind, text: string) {
    // The same message twice in a row just refreshes the first.
    for * app.toasts if it.text == text && !it.leaving { it.born = ui.time; return; }
    t := array_add(*app.toasts);
    t.kind = kind;
    t.text = copy_string(text);
    t.born = ui.time;
    t.life = ifx kind == .ERROR then 7.0 else 4.0;
    if app.toasts.count > 4 app.toasts[0].leaving = true;
}

app_on_connected :: () {
    app.connect.auto_connecting = false;
    if !sync.demo && settings.remember_token token_save(sync.token);
    settings_save();
    if !app.keep_page select_page(.OVERVIEW);
    app.keep_page = false;
}

app_on_webhook_created :: (id: string) {
    app.webhooks.creating = false;
    app.webhooks.select_id = copy_string(id);
}

select_page :: (page: Page) {
    if page == app.page && app.page_t >= 1 return;
    app.previous_page = app.page;
    app.page = page;
    app.page_t = 0;
    app.page_age = 0;
    ui.focus = 0;
    ui_close_popup();
}

ask_confirm :: (kind: Confirm_Kind, title: string, detail: string, action: string, ref := "") {
    c := *app.confirm;
    c.open = true;
    c.kind = kind;
    c.t = 0;
    set_string(*c.title, title);
    set_string(*c.detail, detail);
    set_string(*c.action, action);
    set_string(*c.ref, ref);
}


TOP_BAR_HEIGHT    :: 44.0;
STATUS_BAR_HEIGHT :: 24.0;

record_timings :: () {
    app.cpu_ms[app.history_at]      = clock.cpu_ms;
    app.interval_ms[app.history_at] = clock.frame_interval_ms;
    app.history_at = (app.history_at + 1) % app.cpu_ms.count;
    app.shown_cpu_ms = damp(app.shown_cpu_ms, clock.cpu_ms, 6, ui.dt);
    if clock.frame_interval_ms > 0 && !clock.resumed {
        fps := 1000.0 / max(clock.frame_interval_ms, 0.01);
        app.shown_fps = damp(app.shown_fps, fps, 4, ui.dt);
    }
}

handle_hotkeys :: () {
    typing := ui.text_focus_prev || ui.text_focus;
    if ui.modal_prev return;
    if ctrl_down() {
        for 0..PAGE_COUNT - 1 if letter_pressed(cast(u8) (#char "1" + it)) select_page(cast(Page) it);
        if key_pressed(.TAB) {
            next := (cast(int) app.page + ifx shift_down() then PAGE_COUNT - 1 else 1) % PAGE_COUNT;
            select_page(cast(Page) next);
        }
        if letter_pressed(#char "R") sync_refresh(true);
        if letter_pressed(#char "F") {
            select_page(.TRANSACTIONS);
            app.txn.focus_search = true;
        }
    }
    if key_pressed(.F5) sync_refresh(true);
    if !typing && !ctrl_down() {
        for input.text if it == #char "/" {
            select_page(.TRANSACTIONS);
            app.txn.focus_search = true;
            input.text.count = 0;
            break;
        }
    }
}

//
// The console: top bar, page, status bar.
//

draw_console :: (full: Rect) {
    r := full;
    top := cut_top(*r, px(TOP_BAR_HEIGHT));
    status := cut_bottom(*r, px(STATUS_BAR_HEIGHT));
    draw_top_bar(top);
    draw_status_bar(status);

    ui_animate(*app.page_t, 1, 9);
    app.page_age += ui.dt * max(ui.motion, 0.0001);
    if ui.motion <= 0 app.page_age = 10;
    t := ease_out_cubic(app.page_t);
    direction := ifx cast(int) app.page >= cast(int) app.previous_page then 1.0 else -1.0;

    content := rect_inset_xy(r, px(12), 0);
    content.h -= px(10);
    push_clip(r);
    push_opacity(0.25 + 0.75 * t);
    content.x += px(14) * (1 - t) * direction;
    if app.page == {
        case .OVERVIEW;     draw_overview_page(content);
        case .TRANSACTIONS; draw_transactions_page(content);
        case .ACCOUNTS;     draw_accounts_page(content);
        case .SPENDING;     draw_spending_page(content);
        case .TAGS;         draw_tags_page(content);
        case .WEBHOOKS;     draw_webhooks_page(content);
        case .SETTINGS;     draw_settings_page(content);
    }
    pop_opacity();
    pop_clip();

    // Load progress: a hairline along the bottom of the top bar.
    if sync.phase == .LOADING || sync.refreshing || sync.phase == .CONNECTING {
        bar := rect(top.x, top.y + top.h - px(2), top.w, px(2));
        if sync.phase == .LOADING {
            w := ui_widget(ui_id("load-progress"));
            ui_animate(*w.t, sync_load_progress(), 4);
            fill := bar;
            fill.w = bar.w * w.t;
            draw_rect(fill, theme.accent);
            draw_rect(rect(fill.x + fill.w - px(60), fill.y, px(60), fill.h), color_with_alpha(rgb(0xFFFFFF), 0.25));
        } else {
            // Indeterminate: a segment sweeping across.
            phase := cast(float) fmod_cycling(ui.time * 0.9, 1.0);
            seg_w := bar.w * 0.22;
            x := bar.x - seg_w + (bar.w + seg_w) * ease_in_out_cubic(phase);
            push_clip(bar);
            draw_rect(rect(x, bar.y, seg_w, bar.h), theme.accent);
            pop_clip();
            ui.animating = true;
        }
    }
}

draw_brand :: (r: Rect) -> float {
    mark := snap(rect(r.x, r.y + (r.h - px(20)) * 0.5, px(20), px(20)));
    draw_brand_mark(mark);
    tw := draw_text_in_rect(fonts.semibold, px(14), rect(mark.x + mark.w + px(9), r.y, px(100), r.h), "Uppies", theme.text);
    return mark.w + px(9) + tw;
}

// The app icon (assets/icon.png) drawn from primitives, so it is sharp at
// any scale: a "U" whose right arm rises into an arrow, on a gradient plate.
// Glyph coordinates are the icon's, in which the plate is 224 units across.
draw_brand_mark :: (mark: Rect) {
    draw_rect_gradient(mark, theme.brand_top, theme.brand_bottom, mark.w * 0.26);

    k  := mark.w / 224;
    ox := mark.x + 61.5 * k;   // Glyph origin: the left arm's centerline...
    oy := mark.y + 90.5 * k;   // ...where the arm's straight part begins.
    stroke := 31 * k;
    color  := theme.brand_glyph;

    // The bowl: the bottom of a rounded outline (borders draw inward), with
    // its top cut away where the left arm ends.
    push_clip(rect(mark.x, oy + 4 * k, mark.w, mark.h));
    bowl := rect(ox - 15.5 * k, oy - 40 * k, 105 * k, 148.5 * k);
    draw_rect_ex(bowl, 0, 0, .[0, 0, bowl.w * 0.5, bowl.w * 0.5], stroke, color);
    pop_clip();

    draw_circle(ox, oy + 4 * k, stroke * 0.5, color);                         // Left arm's cap.
    draw_line(ox + 74 * k, oy + 8 * k, ox + 74 * k, oy - 34 * k, stroke, color);  // Right arm.
    draw_line(ox + 47 * k, oy - 19 * k, ox + 74 * k, oy - 46 * k, stroke, color); // Arrowhead.
    draw_line(ox + 74 * k, oy - 46 * k, ox + 101 * k, oy - 19 * k, stroke, color);
}

draw_top_bar :: (r: Rect) {
    draw_rect(r, theme.chrome);
    ui_divider(r.x, r.y + r.h - hairline(), r.w, theme.border);
    bar := rect_inset_xy(r, px(14), 0);
    brand_w := draw_brand(bar);
    cut_left(*bar, brand_w + px(18));
    ui_vdivider(bar.x - px(1), bar.y + px(13), bar.h - px(26), theme.border);
    cut_left(*bar, px(6));

    // Right side: sync state and refresh.
    right := bar;
    refresh_r := cut_right(*right, px(28));
    refresh_r = rect(refresh_r.x, right.y + (right.h - px(28)) * 0.5, px(28), px(28));
    busy := sync_is_busy();
    if ui_icon_button("refresh##top", .REFRESH, refresh_r, ifx sync.phase == .LOADING then "Loading history…" else "Refresh (F5)", enabled = sync.phase == .READY && !sync.refreshing) sync_refresh(true);
    if busy {
        // A small spinner over the button while working.
        draw_spinner(refresh_r.x + refresh_r.w * 0.5, refresh_r.y + refresh_r.h * 0.5, px(7));
    }
    cut_right(*right, px(8));
    status_w := draw_sync_status(right);
    cut_right(*right, status_w + px(12));
    if sync.demo {
        cy := right.y + right.h * 0.5;
        label := "SAMPLE DATA";
        w := measure_text(fonts.semibold, px(theme.font_size_small), label) + px(12);
        draw_chip(right.x + right.w - w, cy, label, theme.info);
        cut_right(*right, w + px(10));
    }

    // Tabs.
    tabs := bar;
    tabs.w = right.x + right.w - tabs.x;
    x := tabs.x;
    active_x, active_w: float;
    for i: 0..PAGE_COUNT - 1 {
        page := cast(Page) i;
        label := PAGE_TITLES[i];
        badge := "";
        badge_color: Color;
        if page == .TRANSACTIONS && analytics.held_count > 0 { badge = tprint("%", analytics.held_count); badge_color = theme.held; }
        if page == .WEBHOOKS && sync.webhooks_state == .LOADED { badge = tprint("%", sync.webhooks.count); badge_color = theme.text_muted; }
        if page == .SETTINGS && sync.auth_failed { badge = "!"; badge_color = theme.danger; }
        tw := measure_text(fonts.semibold, px(13), label);
        bw := ifx badge.count then measure_text(fonts.semibold, px(theme.font_size_small), badge) + px(10) else 0.0;
        w := tw + px(24) + ifx bw > 0 then bw + px(6) else 0.0;
        tab := rect(x, tabs.y, w, tabs.h);
        if x + w > tabs.x + tabs.w break;   // Narrow window: the rest are on Ctrl+number.
        x += w;
        id := ui_id("tab", i);
        tw_state := ui_widget(id);
        io := ui_interact(id, tab);
        ui_focusable(id);
        ui_update_focus(tw_state, id);
        if io.hovered ui.cursor = .HAND;
        if io.pressed { select_page(page); ui_take_focus(id); }
        if ui_key_activate(id) {
            select_page(page);
            ui_take_focus(id, true);   // Keep the keyboard where it was.
        }
        active := app.page == page;
        ui_animate(*tw_state.hover, ifx io.hovered && !active then 1.0 else 0.0, 22);
        ui_animate(*tw_state.press, ifx active then 1.0 else 0.0, 16);
        color := color_lerp(color_lerp(theme.text_muted, theme.text_secondary, tw_state.hover), theme.text, tw_state.press);
        text_r := rect(tab.x + px(12), tab.y, tw + px(2), tab.h);
        draw_text_in_rect(fonts.semibold, px(13), text_r, label, color);
        if badge.count {
            br := snap(rect(text_r.x + tw + px(6), tab.y + (tab.h - px(16)) * 0.5, bw, px(16)));
            draw_rect(br, color_with_alpha(badge_color, 0.14), px(8));
            draw_text_in_rect(fonts.semibold, px(theme.font_size_small), br, badge, badge_color, .CENTER, .{tabular = true});
        }
        ui_focus_ring(rect_inset_xy(tab, px(4), px(9)), tw_state.focus, px(3));
        if active { active_x = tab.x + px(10); active_w = tab.w - px(20); }
    }
    if active_w > 0 {
        if !app.tabs_ready { app.tab_x.value = active_x; app.tab_w.value = active_w; app.tabs_ready = true; }
        ix := ui_spring(*app.tab_x, active_x, 520, 0.84);
        iw := ui_spring(*app.tab_w, active_w, 520, 0.84);
        draw_rect(snap(rect(ix, r.y + r.h - px(2), iw, px(2))), theme.accent);
    }
}

draw_spinner :: (cx: float, cy: float, radius: float, color: Color = 0) {
    c := ifx color then color else theme.text_secondary;
    phase := cast(float) fmod_cycling(ui.time * 1.1, 1.0);
    N :: 8;
    for i: 0..N - 1 {
        a := (i / cast(float) N) * TAU;
        fade := fmod_cycling(phase - i / cast(float) N + 1, 1.0);
        alpha := 0.15 + 0.85 * (1 - fade);
        x0 := cx + cos(a) * radius * 0.45;
        y0 := cy + sin(a) * radius * 0.45;
        x1 := cx + cos(a) * radius;
        y1 := cy + sin(a) * radius;
        draw_line(x0, y0, x1, y1, px(1.6), color_with_alpha(c, alpha));
    }
    ui.animating = true;
}

// "● Synced 14:02 · 3m ago" (right-aligned); returns its width.
draw_sync_status :: (r: Rect) -> float {
    size := px(theme.font_size_label);
    text: string;
    dot := theme.positive;
    if sync.auth_failed {
        text = "Token rejected";
        dot = theme.danger;
    } else if sync.phase == .CONNECTING {
        text = "Connecting…";
        dot = theme.held;
    } else if sync.phase == .LOADING {
        text = tprint("Loading history · % transactions", format_grouped(store.transactions.count));
        dot = theme.held;
    } else if sync.from_saved {
        // Opened from local data; Up hasn't been heard from yet.
        dot = theme.held;
        if sync.error.count text = tprint("Offline · saved data from %", format_relative(app.now.utc_seconds - sync.last_sync_utc));
        else text = "Saved data · checking Up…";
    } else if sync.refreshing {
        text = ifx sync.refresh_kind == .FULL then "Checking all transactions…" else "Refreshing…";
        dot = theme.held;
    } else if sync.error.count {
        text = tprint("Stale · synced %", format_relative(app.now.utc_seconds - sync.last_sync_utc));
        dot = theme.held;
    } else if sync.last_sync_utc {
        ago := app.now.utc_seconds - sync.last_sync_utc;
        local := Timestamp.{sync.last_sync_utc, app.now.offset_minutes};
        text = tprint("Synced % · %", format_time(local), format_relative(ago));
    }
    if !text.count return 0;
    w := measure_text(fonts.regular, size, text);
    x := r.x + r.w - w;
    draw_text_in_rect(fonts.regular, size, rect(x, r.y, w + px(2), r.h), text, theme.text_secondary);
    draw_circle(x - px(9), r.y + r.h * 0.5, px(3.5), dot);
    if sync.error.count {
        id := ui_id("sync-status");
        io := ui_interact(id, rect(x - px(16), r.y, w + px(16), r.h));
        ui_tooltip(id, io.hovered, sync.error);
    }
    return w + px(16);
}

draw_status_bar :: (area: Rect) {
    draw_rect(area, theme.chrome);
    ui_divider(area.x, area.y, area.w, theme.border);
    r := rect_inset_xy(area, px(14), 0);
    size := px(theme.font_size_small);
    sep :: (r: *Rect) {
        x := r.x + px(8);
        ui_vdivider(x, r.y + px(6), r.h - px(12), theme.border_strong);
        cut_left(r, px(17));
    }
    item :: (r: *Rect, text: string, color: Color, mono := false) {
        f := ifx mono then fonts.mono else fonts.regular;
        w := draw_text_in_rect(f, px(theme.font_size_small), r.*, text, color, .LEFT, .{tabular = true});
        cut_left(r, w);
    }

    connected := sync.phase == .READY || sync.phase == .LOADING;
    draw_circle(r.x + px(3), r.y + r.h * 0.5, px(3), ifx sync.auth_failed || sync.error.count then theme.held else ifx connected then theme.positive else theme.text_faint);
    cut_left(*r, px(12));
    item(*r, ifx sync.demo then "Sample data · offline" else "api.up.com.au", theme.text_secondary);
    if api_stats.requests {
        sep(*r);
        item(*r, tprint("% requests · last % ms", format_grouped(api_stats.requests), cast(int) (api_stats.last_ms + 0.5)), theme.text_muted);
    }
    if store.accounts.count {
        sep(*r);
        item(*r, tprint("% accounts · % transactions", store.accounts.count, format_grouped(store.transactions.count)), theme.text_muted);
        if store.transactions.count {
            oldest := store.transactions[store.transactions.count - 1].day;
            sep(*r);
            item(*r, tprint("% since %", ifx sync.history_complete then "History" else "Loaded", format_date(oldest)), theme.text_muted);
        }
    }
    if sync.pending_writes > 0 {
        sep(*r);
        item(*r, tprint("Saving % change%…", sync.pending_writes, ifx sync.pending_writes == 1 then "" else "s"), theme.held);
    }

    hints := tprint("% pages · / search · F5 refresh · Tab focus", shortcut("1–7"));
    minutes := AUTO_REFRESH_MINUTES[settings.auto_refresh];
    auto := ifx minutes > 0 then tprint("Auto-refresh %", AUTO_REFRESH_LABELS[settings.auto_refresh]) else "Auto-refresh off";
    right := tprint("%   ·   %", auto, hints);
    if measure_text(fonts.regular, size, right) < r.w - px(40) draw_text_in_rect(fonts.regular, size, r, right, theme.text_muted, .RIGHT);
}

//
// Toasts: brief confirmations and errors, bottom right, newest at the bottom.
//

draw_toasts :: (full: Rect) {
    if !app.toasts.count return;
    layer := draw_set_layer(.OVERLAY);
    push_clip_absolute(full);
    y := full.y + full.h - px(STATUS_BAR_HEIGHT) - px(12);
    width := px(340);
    i := app.toasts.count - 1;
    while i >= 0 {
        t := *app.toasts[i];
        age := ui.time - t.born;
        if age > t.life t.leaving = true;
        ui_animate(*t.t, ifx t.leaving then 0.0 else 1.0, ifx t.leaving then 14.0 else 18.0);
        if t.leaving && t.t <= 0.001 {
            free(t.text);
            array_ordered_remove_by_index(*app.toasts, i);
            i -= 1;
            continue;
        }
        if !t.leaving ui_wake_at(t.born + t.life);
        e := ease_out_cubic(t.t);
        lines := wrap_lines(fonts.regular, px(theme.font_size_body), t.text, width - px(44));
        h := px(18) * lines.count + px(18);
        y -= h * e + px(8) * e;
        box := snap(rect(full.x + full.w - width - px(14) + px(24) * (1 - e), y, width, h));
        push_opacity(e);
        draw_shadow(box, px(4), px(16), theme.shadow, 0, px(5));
        accent := ifx t.kind == .ERROR then theme.danger else ifx t.kind == .SUCCESS then theme.positive else theme.info;
        draw_rect_outline(box, theme.panel_header, theme.border_strong, hairline(), px(theme.radius_panel));
        draw_rect(snap(rect(box.x, box.y, px(2), box.h)), accent);
        icon := ifx t.kind == .ERROR then Icon.ERROR else ifx t.kind == .SUCCESS then .CHECK else .INFO;
        draw_icon(icon, box.x + px(18), box.y + px(9) + px(9), px(12), accent);
        ty := box.y + px(9);
        for lines {
            draw_text_in_rect(fonts.regular, px(theme.font_size_body), rect(box.x + px(34), ty, box.w - px(44), px(18)), it, theme.text);
            ty += px(18);
        }
        id := ui_id("toast", cast(int) (t.born * 1000));
        ui.in_overlay = true;
        io := ui_interact(id, box);
        ui.in_overlay = false;
        if io.hovered { t.born = ui.time - min(age, cast(float64) t.life - 1.5); ui.cursor = .HAND; }
        if io.clicked t.leaving = true;
        pop_opacity();
        i -= 1;
    }
    pop_clip();
    draw_set_layer(layer);
}

// Greedy word wrap into lines no wider than width. Each word is measured once
// and a line's width is the sum of its words and spaces, so this is linear in
// the text; the lines are slices of it.
wrap_lines :: (font: *Font, size: float, text: string, width: float) -> [] string {
    lines: [..] string;
    lines.allocator = temp;
    space_w := measure_text(font, size, " ");
    start, end := 0;   // The current line is text[start..end).
    line_w := 0.0;
    i := 0;
    while i < text.count {
        j := i;
        while j < text.count && text[j] != #char " " j += 1;
        if j > i {
            word_w := measure_text(font, size, slice(text, i, j - i));
            if end == start {
                start = i;
                line_w = word_w;
            } else if line_w + space_w * (i - end) + word_w > width {
                array_add(*lines, slice(text, start, end - start));
                start = i;
                line_w = word_w;
            } else {
                line_w += space_w * (i - end) + word_w;
            }
            end = j;
        }
        i = j + 1;
    }
    if end > start array_add(*lines, slice(text, start, end - start));
    return lines;
}

//
// Confirmation dialog.
//

draw_confirm :: () {
    c := *app.confirm;
    if !c.open && c.t <= 0.001 return;
    ui_animate(*c.t, ifx c.open then 1.0 else 0.0, 18);
    lines := wrap_lines(fonts.regular, px(theme.font_size_body), c.detail, px(380));
    h := px(110) + lines.count * px(19);
    box := ui_modal_begin(px(420), h, c.t);
    inner := rect_inset_xy(box, px(20), px(18));
    draw_text_in_rect(fonts.semibold, px(15), cut_top(*inner, px(22)), c.title, theme.text);
    cut_top(*inner, px(8));
    for lines draw_text_in_rect(fonts.regular, px(theme.font_size_body), cut_top(*inner, px(19)), it, theme.text_secondary);
    buttons := cut_bottom(*inner, px(theme.control_height));
    destructive := c.kind == .DELETE_WEBHOOK || c.kind == .DISCONNECT || c.kind == .DELETE_LOCAL_DATA;
    action_r := cut_right(*buttons, ui_button_width(c.action));
    cut_right(*buttons, px(8));
    cancel_r := cut_right(*buttons, ui_button_width("Cancel"));
    if c.open {
        if ui_button(tprint("%##confirm", c.action), action_r, ifx destructive then Button_Style.DANGER else .PRIMARY) {
            c.open = false;
            if c.kind == {
                case .DELETE_WEBHOOK; sync_delete_webhook(c.ref);
                case .DISCONNECT;
                    token_forget();
                    sync_disconnect();
                    app.connect.token.count = 0;
                case .DELETE_LOCAL_DATA;
                    sync_reload_all();   // Deletes the file, then downloads everything.
                    app_toast(.INFO, "Local data deleted. Downloading everything from Up again.");
            }
        }
        if ui_button("Cancel##confirm", cancel_r, .SECONDARY) || key_pressed(.ESCAPE) {
            c.open = false;
            input.key_pressed[Key.ESCAPE] = false;
        }
        if key_pressed(.ENTER) && ui.focus == 0 {
            // Enter confirms only when nothing else is focused... and never for destructive actions.
            if !destructive c.open = false;
        }
    }
    ui_modal_end();
}

//
// Connect screen.
//

Connect_State :: struct {
    token: Text_Buffer;
    show_token: bool;
    auto_connecting: bool;
    focused: bool;   // The token field takes focus when the screen first shows.
}

draw_connect_screen :: (full: Rect) {
    r := full;
    top := cut_top(*r, px(TOP_BAR_HEIGHT));
    draw_rect(top, theme.chrome);
    ui_divider(top.x, top.y + top.h - hairline(), top.w, theme.border);
    draw_brand(rect_inset_xy(top, px(14), 0));

    st := *app.connect;
    connecting := sync.phase == .CONNECTING;

    if st.auto_connecting && connecting {
        draw_spinner(r.x + r.w * 0.5, r.y + r.h * 0.5 - px(14), px(10), theme.accent);
        draw_text_in_rect(fonts.regular, px(theme.font_size_body), rect(r.x, r.y + r.h * 0.5 + px(4), r.w, px(20)), ifx sync.demo then "Opening sample data…" else "Connecting to Up…", theme.text_secondary, .CENTER);
        return;
    }

    width := px(480);
    height := px(452);
    box := snap(rect(r.x + (r.w - width) * 0.5, r.y + max((r.h - height) * 0.42, px(20)), width, height));
    draw_rect_outline(box, theme.panel, theme.border, hairline(), px(theme.radius_panel));
    inner := rect_inset_xy(box, px(28), px(24));

    draw_caps(cut_top(*inner, px(14)), "Up API", theme.accent);
    cut_top(*inner, px(6));
    draw_text_in_rect(fonts.semibold, px(20), cut_top(*inner, px(28)), "Connect your Up account", theme.text);
    cut_top(*inner, px(8));
    intro := tprint("Uppies reads your accounts and transactions with a personal access token. The token stays on %, encrypted for %, and is only ever sent to api.up.com.au.", PLATFORM_DEVICE, PLATFORM_ACCOUNT);
    for wrap_lines(fonts.regular, px(theme.font_size_body), intro, inner.w) draw_text_in_rect(fonts.regular, px(theme.font_size_body), cut_top(*inner, px(19)), it, theme.text_secondary);
    cut_top(*inner, px(6));
    link_r := cut_top(*inner, px(20));
    if ui_link("Get a token at api.up.com.au/getting_started", link_r) platform_open_url("https://api.up.com.au/getting_started");
    draw_icon(.OPEN_EXTERNAL, link_r.x + measure_text(fonts.regular, px(theme.font_size_label), "Get a token at api.up.com.au/getting_started") + px(9), link_r.y + link_r.h * 0.5, px(10), theme.accent);

    cut_top(*inner, px(18));
    draw_caps(cut_top(*inner, px(14)), "Personal access token", theme.text_muted);
    cut_top(*inner, px(6));
    field_row := cut_top(*inner, px(32));
    eye := cut_right(*field_row, px(32));
    cut_right(*field_row, px(6));
    flags := Text_Input_Flags.MONO;
    if !st.show_token flags |= .PASSWORD;
    if !st.focused && !connecting {
        st.focused = true;
        ui.focus = ui_id("token##connect");
        ui.focus_visible = false;
    }
    _, submitted := ui_text_input("token##connect", field_row, *st.token, "up:yeah:…", flags);
    if ui_icon_button("show-token", ifx st.show_token then Icon.HIDE else .VIEW, eye, ifx st.show_token then "Hide token" else "Show token", st.show_token) st.show_token = !st.show_token;

    cut_top(*inner, px(10));
    ui_checkbox(tprint("Remember on % (encrypted with %)", PLATFORM_DEVICE, PLATFORM_SECRET_STORE), cut_top(*inner, px(22)), *settings.remember_token);

    cut_top(*inner, px(14));
    buttons := cut_top(*inner, px(32));
    token := trim(buffer_string(*st.token));
    can_connect := token.count > 0 && !connecting;
    connect_r := cut_left(*buttons, px(120));
    if ui_button(ifx connecting then "Checking…##connect" else "Connect##connect", connect_r, .PRIMARY, enabled = can_connect) || (submitted && can_connect) {
        sync_start(token, false);
    }
    if connecting && !sync.demo draw_spinner(connect_r.x + connect_r.w + px(16), connect_r.y + connect_r.h * 0.5, px(7));

    if sync.connect_error.count {
        cut_top(*inner, px(12));
        error_lines := wrap_lines(fonts.regular, px(theme.font_size_label), sync.connect_error, inner.w - px(20));
        er := cut_top(*inner, px(14) + error_lines.count * px(17));
        draw_icon(.ERROR, er.x + px(6), er.y + px(14), px(11), theme.danger);
        ty := er.y + px(6);
        for error_lines {
            draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(er.x + px(20), ty, er.w - px(20), px(17)), it, theme.danger);
            ty += px(17);
        }
    }

    // Sample data.
    bottom := cut_bottom(*inner, px(58));
    ui_divider(bottom.x, bottom.y, bottom.w, theme.border);
    cut_top(*bottom, px(14));
    sample_r := cut_left(*bottom, px(170));
    sample_r.h = px(30);
    if ui_button("Explore with sample data", sample_r, .SECONDARY, .LIGHTNING, enabled = !connecting) sync_start("", true);
    note := rect(bottom.x + px(14), bottom.y, bottom.w - px(14), px(30));
    draw_text_fit(fonts.regular, px(theme.font_size_label), rect(note.x, note.y, note.w, px(15)), "Two years of generated activity.", theme.text_muted);
    draw_text_fit(fonts.regular, px(theme.font_size_label), rect(note.x, note.y + px(15), note.w, px(15)), "Nothing is sent anywhere.", theme.text_muted);
}
