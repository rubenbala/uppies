// Webhooks: are my webhooks set up, and are their deliveries arriving?
//
// Up allows ten webhooks. Creating one returns its secret key once (it
// signs every delivery); this page shows it until dismissed and never again.

Webhooks_State :: struct {
    table:       Table_State;
    selected_id: string;
    select_id:   string;   // Set after creating: select the new one.
    creating:    bool;
    url:         Text_Buffer;
    description: Text_Buffer;
    form_error:  string;
    logs_table:  Table_State;
    log_scroll:  Scroll;
    logs_shown:  string;   // The webhook whose log the table shows.
}

draw_webhooks_page :: (r_in: Rect) {
    st := *app.webhooks;
    r := r_in;
    if sync.phase == .READY && sync.webhooks_state == .IDLE sync_load_webhooks();

    bar := toolbar_rect(*r);
    if ui_button("New webhook", cut_left(*bar, px(128)), .PRIMARY, .ADD, enabled = sync.phase == .READY && sync.webhooks.count < 10) {
        st.creating = true;
        st.url.count = 0;
        st.description.count = 0;
        set_string(*st.form_error, "");
    }
    cut_left(*bar, px(8));
    if ui_button("Reload##webhooks", cut_left(*bar, px(86)), .SECONDARY, .REFRESH, enabled = sync.phase == .READY && sync.webhooks_state != .LOADING) {
        sync.webhooks_state = .IDLE;
        sync_load_webhooks();
        if st.selected_id.count sync_load_logs(st.selected_id);
    }
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), bar, tprint("% of 10 webhooks · events: transaction created, settled, deleted, and ping", sync.webhooks.count), theme.text_muted, .RIGHT);

    if sync.phase == .LOADING && !sync.history_complete && sync.webhooks_state == .IDLE {
        content, _ := panel_begin(r, "Webhooks");
        draw_empty_state(content, "Webhooks load once the account data has loaded", "", .SYNC);
        return;
    }

    // The one-time secret.
    if sync.new_secret.count {
        banner := cut_top(*r, px(76));
        cut_top(*r, px(8));
        draw_secret_banner(banner);
    }

    left := cut_left(*r, r.w * 0.46);
    cut_left(*r, px(8));
    if st.creating {
        form := cut_top(*left, px(178));
        cut_top(*left, px(8));
        draw_create_form(appear_begin(form, 0), st);
        appear_end();
    }
    rows := max(sync.webhooks.count, 4);
    table_h := px(theme.panel_header_height + 26 + 2) + rows * px(36);
    if left.h - table_h < px(220) table_h = left.h;
    draw_webhook_table(appear_begin(cut_top(*left, table_h), 1), st);
    appear_end();
    if left.h > px(220) {
        cut_top(*left, px(8));
        draw_reference(appear_begin(left, 3));
        appear_end();
    }
    draw_webhook_detail(appear_begin(r, 2), st);
    appear_end();
}

#scope_file

Health_Segment :: struct { n: int; c: Color; }

draw_secret_banner :: (r: Rect) {
    b := snap(r);
    draw_rect_outline(b, color_with_alpha(theme.held, 0.08), color_with_alpha(theme.held, 0.45), hairline(), px(theme.radius_panel));
    inner := rect_inset_xy(b, px(16), px(12));
    draw_icon(.LOCK, inner.x + px(7), inner.y + px(9), px(13), theme.held);
    cut_left(*inner, px(24));
    buttons := cut_right(*inner, px(170));
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), rect(inner.x, inner.y, inner.w, px(18)), "Secret key for the new webhook: copy it now. Up shows it only once.", theme.text);
    draw_text_fit(fonts.mono, px(theme.font_size_body), rect(inner.x, inner.y + px(26), inner.w, px(22)), sync.new_secret, theme.held);
    br := rect(buttons.x, buttons.y + px(12), px(80), px(28));
    if ui_button("Copy##secret", br, .SECONDARY, .COPY) {
        platform_clipboard_set(sync.new_secret);
        app_toast(.SUCCESS, "Secret key copied.");
    }
    if ui_button("Done##secret", rect(br.x + px(88), br.y, px(80), px(28)), .GHOST) {
        // Overwrite before letting it go.
        for 0..sync.new_secret.count - 1 sync.new_secret[it] = 0;
        set_string(*sync.new_secret, "");
    }
}

draw_create_form :: (r: Rect, st: *Webhooks_State) {
    content, header := panel_begin(r, "New webhook");
    if ui_icon_button("close##create", .CLOSE, cut_right(*header, px(26)), "Cancel") st.creating = false;
    inner := rect_inset_xy(content, px(14), px(10));
    draw_caps(cut_top(*inner, px(14)), "URL", theme.text_muted);
    cut_top(*inner, px(4));
    _, submit1 := ui_text_input("url##create", cut_top(*inner, px(30)), *st.url, "https://example.com/up-webhook", .MONO, max_length = 300);
    cut_top(*inner, px(8));
    draw_caps(cut_top(*inner, px(14)), "Description (optional)", theme.text_muted);
    cut_top(*inner, px(4));
    row := cut_top(*inner, px(30));
    create_r := cut_right(*row, px(96));
    cut_right(*row, px(8));
    _, submit2 := ui_text_input("description##create", row, *st.description, "What receives these events", max_length = 64);
    url := trim(buffer_string(*st.url));
    valid := begins_with(url, "https://") || begins_with(url, "http://");
    if ui_button("Create##webhook", create_r, .PRIMARY, enabled = url.count > 0 && sync.webhook_busy == 0) || ((submit1 || submit2) && url.count) {
        if !valid {
            set_string(*st.form_error, "The URL must start with https:// (or http://).");
        } else {
            set_string(*st.form_error, "");
            sync_create_webhook(url, trim(buffer_string(*st.description)));
        }
    }
    cut_top(*inner, px(6));
    if st.form_error.count draw_text_fit(fonts.regular, px(theme.font_size_label), cut_top(*inner, px(16)), st.form_error, theme.danger);
    else draw_text_fit(fonts.regular, px(theme.font_size_label), cut_top(*inner, px(16)), "Up POSTs JSON events here and expects a 200 response. Send a ping after creating it.", theme.text_muted);
}

WEBHOOK_COLUMNS :: Column.[
    .{"URL",         0,   .LEFT,  false, 0},
    .{"Description", 150, .LEFT,  false, 600},
    .{"Created",     88,  .RIGHT, false, 0},
];

draw_webhook_table :: (r: Rect, st: *Webhooks_State) {
    content, _ := panel_begin(r, "Webhooks", ifx sync.webhooks_state == .LOADING then "loading…" else "");
    if st.select_id.count {
        set_string(*st.selected_id, st.select_id);
        set_string(*st.select_id, "");
        sync_load_logs(st.selected_id);
    }
    selected_row := -1;
    for sync.webhooks if it.id == st.selected_id selected_row = it_index;
    if selected_row < 0 && sync.webhooks.count {
        selected_row = 0;
        set_string(*st.selected_id, sync.webhooks[0].id);
        sync_load_logs(st.selected_id);
    }
    st.table.selected = selected_row;
    tbl: Data_Table;
    table_begin(*tbl, "webhooks-table", content, WEBHOOK_COLUMNS, *st.table, sync.webhooks.count, keyboard = true, row_height = px(36));
    if sync.webhooks_state == .LOADING && !sync.webhooks.count {
        table_end(*tbl);
        table_skeleton(*tbl, 3);
        return;
    }
    if sync.webhooks_state == .FAILED {
        table_end(*tbl);
        draw_empty_state(content, "Couldn't load webhooks", sync.webhooks_error, .ERROR);
        return;
    }
    if !sync.webhooks.count {
        table_end(*tbl);
        draw_empty_state(content, "No webhooks", "Create one to have Up send transaction events to your own service.", .LINK);
        return;
    }
    for i: tbl.first..tbl.last {
        w := *sync.webhooks[i];
        row := table_row(*tbl, i);
        url_r := table_cell(*tbl, row, 0);
        draw_text_fit(fonts.mono, px(theme.font_size_label), rect(url_r.x, url_r.y + px(3), url_r.w, px(16)), w.url, theme.text);
        draw_text_fit(fonts.mono, px(theme.font_size_small), rect(url_r.x, url_r.y + px(19), url_r.w, px(14)), w.id, theme.text_faint);
        if table_column_shown(*tbl, 1) draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), ifx w.description.count then w.description else "—", ifx w.description.count then theme.text_secondary else theme.text_faint);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 2), format_date(ts_day(w.created)), theme.text_muted, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if tbl.selection_changed && st.table.selected >= 0 && st.table.selected < sync.webhooks.count {
        set_string(*st.selected_id, sync.webhooks[st.table.selected].id);
        sync_load_logs(st.selected_id);
    }
}

LOG_COLUMNS :: Column.[
    .{"Time",     118, .LEFT,  false, 0},
    .{"Event",    0,   .LEFT,  false, 0},
    .{"Delivery", 112, .LEFT,  false, 0},
    .{"HTTP",     52,  .RIGHT, false, 0},
];

draw_webhook_detail :: (r_in: Rect, st: *Webhooks_State) {
    r := r_in;
    hook: *Webhook;
    for * sync.webhooks if it.id == st.selected_id hook = it;
    if !hook {
        content, _ := panel_begin(r, "Deliveries");
        draw_empty_state(content, "Select a webhook to see its deliveries", "", .LINK);
        return;
    }

    // Summary and actions.
    head := cut_top(*r, px(96));
    cut_top(*r, px(8));
    content, header := panel_begin(head, ifx hook.description.count then hook.description else "Webhook");
    del_r := cut_right(*header, px(82));
    cut_right(*header, px(6));
    ping_r := cut_right(*header, px(96));
    if ui_button("Send ping##webhook", ping_r, .SECONDARY, .LIGHTNING, enabled = sync.webhook_busy == 0) sync_ping_webhook(hook.id);
    if ui_button("Delete##webhook", del_r, .DANGER, .DELETE, enabled = sync.webhook_busy == 0) {
        ask_confirm(.DELETE_WEBHOOK, "Delete this webhook?", tprint("Up will stop sending events to %. This can't be undone; you can create it again, with a new secret key.", hook.url), "Delete webhook", hook.id);
    }
    inner := rect_inset_xy(content, px(14), px(8));
    url_row := cut_top(*inner, px(22));
    copy_r := cut_right(*url_row, px(24));
    draw_field(url_row, "URL", hook.url, true);
    if ui_icon_button("copy-url##webhook", .COPY, rect(copy_r.x, copy_r.y, px(22), px(22)), "Copy URL") { platform_clipboard_set(hook.url); app_toast(.SUCCESS, "URL copied."); }

    // Delivery health from what's loaded.
    delivered, bad, undeliverable := 0, 0, 0;
    for sync.logs if it.delivery == {
        case .DELIVERED;         delivered += 1;
        case .BAD_RESPONSE_CODE; bad += 1;
        case;                    undeliverable += 1;
    }
    total := sync.logs.count;
    health := cut_top(*inner, px(24));
    if total {
        label_w := px(112);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(health.x, health.y, label_w, health.h), tprint("Last %", total), theme.text_muted);
        bar := rect(health.x + label_w, health.y + px(8), min(px(160), health.w - label_w - px(220)), px(8));
        x := bar.x;
        segments := Health_Segment.[.{delivered, theme.positive}, .{bad, theme.held}, .{undeliverable, theme.danger}];
        for segments {
            if !it.n continue;
            w := bar.w * it.n / cast(float) total;
            draw_rect(snap(rect(x, bar.y, max(w - px(1), px(1)), bar.h)), it.c, px(1));
            x += w;
        }
        text := tprint("% delivered · % bad response · % undeliverable", delivered, bad, undeliverable);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(bar.x + bar.w + px(12), health.y, health.w - label_w - bar.w - px(12), health.h), text, theme.text_secondary);
    } else if sync.logs_state == .LOADING {
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), health, "Loading deliveries…", theme.text_muted);
    } else {
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), health, "No deliveries yet. Send a ping to test the endpoint.", theme.text_muted);
    }

    // Log table and the selected delivery's payloads.
    log_r := cut_top(*r, r.h * 0.55);
    cut_top(*r, px(8));
    lc, lh := panel_begin(log_r, "Delivery log", ifx sync.logs_next.count then "newest first · more available" else "newest first", controls = 96);
    if sync.logs_next.count {
        if ui_button("Load more##logs", cut_right(*lh, px(92)), .GHOST, enabled = sync.logs_state != .LOADING) sync_load_logs(hook.id, true);
    }
    // A fresh log opens on its newest delivery.
    if st.logs_shown != sync.logs_for {
        set_string(*st.logs_shown, sync.logs_for);
        st.logs_table.selected = -1;
        st.logs_table.scroll = .{};
    }
    if st.logs_table.selected < 0 && sync.logs.count st.logs_table.selected = 0;
    tbl: Data_Table;
    table_begin(*tbl, "webhook-logs", lc, LOG_COLUMNS, *st.logs_table, sync.logs.count, keyboard = true);
    if sync.logs_state == .LOADING && !sync.logs.count {
        table_end(*tbl);
        table_skeleton(*tbl, 6);
    } else {
        for i: tbl.first..tbl.last {
            l := *sync.logs[i];
            row := table_row(*tbl, i);
            when := Timestamp.{l.created.utc, app.now.offset_minutes};
            draw_text_in_rect(fonts.mono, px(theme.font_size_small), table_cell(*tbl, row, 0), tprint("% %", format_date_column(ts_day(when)), format_time_seconds(when)), theme.text_secondary);
            event := table_cell(*tbl, row, 1);
            draw_text_fit(fonts.mono, px(theme.font_size_small), event, l.event_type, theme.text);
            status := table_cell(*tbl, row, 2);
            if l.delivery == {
                case .DELIVERED;         draw_chip(status.x, status.y + status.h * 0.5, "Delivered", theme.positive, .CHECK);
                case .BAD_RESPONSE_CODE; draw_chip(status.x, status.y + status.h * 0.5, "Bad response", theme.held, .WARNING);
                case;                    draw_chip(status.x, status.y + status.h * 0.5, "Undeliverable", theme.danger, .ERROR);
            }
            draw_text_in_rect(fonts.mono, px(theme.font_size_small), table_cell(*tbl, row, 3), ifx l.has_response then tprint("%", l.status_code) else "—",
                              ifx l.status_code == 200 then theme.text_secondary else theme.held, .RIGHT);
        }
        table_end(*tbl);
        if !sync.logs.count && sync.logs_state == .LOADED draw_empty_state(lc, "No deliveries yet");
    }

    pc, _ := panel_begin(r, "Payload", "request body sent by Up, and your endpoint's response");
    sel := st.logs_table.selected;
    if sel < 0 || sel >= sync.logs.count {
        draw_empty_state(pc, "Select a delivery to see its payload", "", .VIEW);
        return;
    }
    l := *sync.logs[sel];
    lines := json_pretty_lines(l.request_body);
    view := rect_inset_xy(pc, px(12), px(8));
    line_h := px(17);
    response := ifx l.has_response then l.response_body else "(no response: the endpoint couldn't be reached)";
    content_h := (lines.count + 3) * line_h;
    offset := ui_scroll_area(ui_id("payload-scroll"), view, *st.log_scroll, content_h);
    push_clip(view);
    y := view.y - offset;
    for lines {
        if y > view.y - line_h && y < view.y + view.h draw_json_line(rect(view.x, y, view.w, line_h), it);
        y += line_h;
    }
    y += line_h * 0.5;
    draw_text_fit(fonts.mono, px(theme.font_size_small), rect(view.x, y, view.w, line_h), tprint("← % %", ifx l.has_response then tprint("%", l.status_code) else "", response), ifx l.status_code == 200 then theme.positive else theme.held);
    pop_clip();
    ui_scroll_draw(*st.log_scroll);
}

// How deliveries arrive and how to check them (from Up's API reference).
draw_reference :: (r: Rect) {
    content, _ := panel_begin(r, "Receiving events");
    inner := rect_inset_xy(content, px(16), px(12));
    size := px(theme.font_size_label);
    line_h := px(18);
    paragraph :: (text: string, inner: *Rect, color: Color) {
        size := px(theme.font_size_label);
        line_h := px(18);
        for wrap_lines(fonts.regular, size, text, inner.w) {
            if inner.h < line_h break;
            draw_text_in_rect(fonts.regular, size, cut_top(inner, line_h), it, color);
        }
        cut_top(inner, px(8));
    }
    heading :: (text: string, inner: *Rect) {
        if inner.h < px(40) return;
        draw_caps(cut_top(inner, px(14)), text, theme.text_muted);
        cut_top(inner, px(6));
    }
    code :: (text: string, inner: *Rect) {
        if inner.h < px(24) return;
        box := cut_top(inner, px(24));
        draw_rect_outline(snap(box), theme.chrome, theme.border, hairline(), px(2));
        draw_text_fit(fonts.mono, px(theme.font_size_small), rect_inset_xy(box, px(8), 0), text, theme.text);
        cut_top(inner, px(8));
    }
    heading("Verify each delivery", *inner);
    paragraph("Up signs every request. Compute the SHA-256 HMAC of the raw request body with the webhook's secret key, and compare it with this header:", *inner, theme.text_secondary);
    code("X-Up-Authenticity-Signature: <hex HMAC-SHA256(secretKey, body)>", *inner);
    heading("Respond quickly with 200", *inner);
    paragraph("Anything else, a timeout or an unreachable URL counts as a failure, and Up retries with exponential backoff. Do slow work after responding.", *inner, theme.text_secondary);
    heading("Events", *inner);
    events := string.[
        "TRANSACTION_CREATED", "a transaction appeared (held or settled)",
        "TRANSACTION_SETTLED", "a held transaction settled",
        "TRANSACTION_DELETED", "a held transaction was removed",
        "PING",                "sent by \"Send ping\", for testing",
    ];
    for i: 0..events.count / 2 - 1 {
        if inner.h < line_h break;
        row := cut_top(*inner, line_h + px(2));
        draw_text_in_rect(fonts.mono, px(theme.font_size_small), rect(row.x, row.y, px(170), row.h), events[i * 2], theme.text);
        draw_text_fit(fonts.regular, size, rect(row.x + px(170), row.y, row.w - px(170), row.h), events[i * 2 + 1], theme.text_secondary);
    }
}

// Indents JSON for reading (strings are left untouched).
json_pretty_lines :: (text: string) -> [] string {
    lines: [..] string;
    lines.allocator = temp;
    builder: String_Builder;
    builder.allocator = temp;
    depth := 0;
    in_string := false;
    escaped := false;
    flush :: () #expand {
        line := builder_to_string(*builder,, temp);
        if trim(line).count array_add(*lines, line);
    }
    indent :: (d: int) #expand { for 1..d append(*builder, "  "); }
    for i: 0..text.count - 1 {
        c := text[i];
        if in_string {
            append(*builder, c);
            if escaped escaped = false;
            else if c == #char "\\" escaped = true;
            else if c == #char "\"" in_string = false;
            continue;
        }
        if c == {
            case #char "\""; in_string = true; append(*builder, c);
            case #char "{"; #through;
            case #char "[";
                append(*builder, c);
                depth += 1;
                flush();
                indent(depth);
            case #char "}"; #through;
            case #char "]";
                flush();
                depth -= 1;
                indent(depth);
                append(*builder, c);
            case #char ",";
                append(*builder, c);
                flush();
                indent(depth);
            case #char ":"; append(*builder, ": ");
            case #char " "; #through;
            case #char "\n"; #through;
            case #char "\r"; #through;
            case #char "\t";
            case; append(*builder, c);
        }
    }
    flush();
    return lines;
}

// Keys muted, values bright: enough color to scan structure.
draw_json_line :: (r: Rect, line: string) {
    size := px(theme.font_size_small);
    found, key, rest := split_from_left(line, "\": ");
    if found {
        kw := draw_text_in_rect(fonts.mono, size, r, tprint("%\":", key), theme.text_muted);
        draw_text_fit(fonts.mono, size, rect(r.x + kw + px(6), r.y, r.w - kw - px(6), r.h), rest, theme.text);
    } else {
        draw_text_fit(fonts.mono, size, r, line, theme.text_secondary);
    }
}
