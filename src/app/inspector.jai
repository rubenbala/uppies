// The transaction inspector: everything the API says about one
// transaction, the controls to recategorise and tag it, and how it compares
// with the other purchases from the same merchant.

Inspector_State :: struct {
    scroll:    Scroll;
    tag_input: Text_Buffer;
    shown_id:  string;
    switch_t:  float = 1;
    category_choice: int;
    bulk:      bool;          // Showing several transactions.
    bulk_tag_input: Text_Buffer;

    merchant_key:   u64;
    merchant_count: int;
    merchant_total: s64;
    merchant_first: s64;
    merchant_recent: [6] s32;
    merchant_recent_count: int;
}

// Returns true when the close button was pressed.
draw_inspector :: (r: Rect, st: *Inspector_State, index: s32) -> bool {
    close := false;
    content, header := panel_begin(r, "Transaction");
    close_r := cut_right(*header, px(26));
    print_r := cut_right(*header, px(26));
    if ui_icon_button("close##inspector", .CLOSE, close_r, "Close (Esc)") close = true;
    if index < 0 || index >= store.transactions.count return close;
    if ui_icon_button("print##inspector", .PRINT, print_r, tprint("Save as PDF (%)", shortcut("P"))) || (ctrl_letter_pressed(#char "P") && !ui.modal_prev) {
        // The Save dialog blocks until it closes; the frame carries on after.
        save_transaction_pdf(index);
    }
    t := *store.transactions[index];

    // Switching transactions: content cross-fades and the form resets.
    if st.shown_id != t.id || st.bulk {
        set_string(*st.shown_id, t.id);
        st.bulk = false;
        st.switch_t = 0;
        st.scroll = .{};
        st.tag_input.count = 0;
    }
    ui_animate(*st.switch_t, 1, 14);
    update_merchant(st, index);

    view := rect_inset_xy(content, 0, 0);
    offset := ui_scroll_area(ui_id("inspector-scroll"), view, *st.scroll, st.scroll.content);
    push_clip(view);
    push_opacity(0.3 + 0.7 * st.switch_t);
    pad := px(16);
    x := view.x + pad;
    w := view.w - 2 * pad - px(6);
    y := view.y + px(14) - offset + px(6) * (1 - st.switch_t);
    top := y;

    // Heading.
    for wrap_lines(fonts.semibold, px(16), t.description, w) {
        if it_index >= 2 break;
        draw_text_in_rect(fonts.semibold, px(16), rect(x, y, w, px(22)), it, theme.text);
        y += px(22);
    }
    y += px(4);
    amount_r := rect(x, y, w, px(34));
    aw := draw_text_in_rect(fonts.numeric, px(28), amount_r, format_money(t.amount, .ALWAYS), ifx t.amount > 0 then theme.positive else theme.text, .LEFT, .{tabular = true});
    if t.status == .HELD draw_chip(x + aw + px(12), y + px(17), "Held", theme.held, .CLOCK);
    y += px(36);
    when := tprint("% · %", format_weekday_date(t.day, app.today), format_time(t.created));
    if t.status == .HELD when = tprint("% · waiting to settle", when);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(x, y, w, px(16)), when, theme.text_muted);
    y += px(26);

    // Category: the one thing most often fixed.
    section("Category", *y, x, w);
    if t.categorizable {
        items, map := category_picker_items();
        st.category_choice = index_of_value(map, t.category);
        picked := st.category_choice;
        if ui_dropdown("category##inspector", rect(x, y, w, px(30)), items, *picked, popup_width = w) {
            if picked >= 0 && picked < map.count && map[picked] != -3 sync_set_category(index, map[picked]);
        }
        y += px(30);
        y += px(6);
        hint := ifx t.category >= 0 then tprint("In %", store.categories[category_root(*store, t.category)].name) else "Not in any category yet";
        draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(x, y, w, px(14)), hint, theme.text_faint);
        y += px(20);
    } else {
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(x, y, w, px(18)), "Not categorisable: transfers, interest and payments to people aren't.", theme.text_muted);
        y += px(26);
    }

    // Tags.
    section("Tags", *y, x, w, tprint("% of %", t.tag_count, MAX_TAGS));
    chip_x := x;
    to_remove: s32 = -1;
    has := NewArray(store.tags.count, bool,, temp);
    for i: 0..t.tag_count - 1 {
        tag := t.tags[i];
        has[tag] = true;
        if tag_chip(*chip_x, *y, x, w, tag, tprint("Remove \"%\"", store.tags[tag].label)) to_remove = tag;
    }
    if t.tag_count y += px(32);
    if to_remove >= 0 sync_remove_tag(index, to_remove);

    if t.tag_count < MAX_TAGS {
        add_r := rect(x, y, w, px(30));
        button_r := cut_right(*add_r, px(64));
        cut_right(*add_r, px(6));
        changed, submitted := ui_text_input("tag##inspector", add_r, *st.tag_input, "Add a tag…", .CLEARABLE, max_length = 60);
        label := trim(buffer_string(*st.tag_input));
        if ui_button("Add##tag", button_r, .SECONDARY, .ADD, enabled = label.count > 0) || (submitted && label.count) {
            sync_add_tag(index, label);
            st.tag_input.count = 0;
        }
        y += px(36);
        suggested := tag_suggestions(x, *y, w, label, has);
        if suggested >= 0 { sync_add_tag(index, store.tags[suggested].label); st.tag_input.count = 0; }
    }

    // Details.
    section("Details", *y, x, w);
    field("Account", account_name(*store, t.account), *y, x, w);
    if t.transfer_account >= 0 field(ifx t.amount < 0 then "Transferred to" else "Transferred from", account_name(*store, t.transfer_account), *y, x, w);
    method := "";
    if t.card_method != .NONE {
        method = CARD_METHOD_NAMES[t.card_method];
        if t.card_suffix.count method = tprint("% · card •••• %", method, t.card_suffix);
    }
    kind := t.transaction_type;
    if method.count kind = ifx kind.count then tprint("% · %", kind, method) else method;
    field("Type", kind, *y, x, w);
    field("Message", t.message, *y, x, w);
    field("Note", t.note, *y, x, w);
    field("Paid by", t.performer, *y, x, w);
    if t.has_foreign field("Foreign amount", format_foreign(t.foreign_currency, t.foreign_value), *y, x, w, true);
    if t.has_hold && t.hold_amount != t.amount field("Held at", format_money(t.hold_amount), *y, x, w, false, theme.held);
    if t.has_round_up {
        text := format_money(t.round_up);
        if t.round_up_boost text = tprint("% (incl. % boost)", text, format_money(-t.round_up_boost));
        field("Round Up", text, *y, x, w);
    }
    if t.has_cashback field("Cashback", tprint("% · %", format_money(t.cashback, .ALWAYS), t.cashback_description), *y, x, w, false, theme.positive);
    field("Raw text", t.raw_text, *y, x, w, true);
    field("Created", format_timestamp_full(t.created), *y, x, w, true);
    if t.has_settled field("Settled", format_timestamp_full(t.settled), *y, x, w, true);
    else field("Settled", "Not yet", *y, x, w, false, theme.held);

    // The id, with a copy button.
    id_r := rect(x, y, w, px(22));
    copy_r := cut_right(*id_r, px(24));
    draw_field(id_r, "Transaction ID", t.id, true);
    if ui_icon_button("copy-id##inspector", .COPY, rect(copy_r.x, copy_r.y, px(22), px(22)), "Copy ID") {
        platform_clipboard_set(t.id);
        app_toast(.SUCCESS, "Transaction ID copied.");
    }
    y += px(26);

    if t.attachment_id.count {
        y += px(4);
        if ui_button("Open receipt##inspector", rect(x, y, px(140), px(28)), .SECONDARY, .ATTACH) sync_open_attachment(t.attachment_id);
        y += px(36);
    }

    // The recurring series it belongs to.
    series := recurring_series_of(index);
    if series && !series.hidden {
        section("Recurring", *y, x, w, RECURRING_KIND_LABELS[series.kind]);
        text := recurring_amount_text(series);
        if series.active text = tprint("% · next %", text, format_weekday_date(series.next_day, app.today));
        else text = tprint("% · ended %", text, format_date(series.last_day));
        if ui_link(tprint("%##inspector-recurring", text), rect(x, y, w, px(18))) show_recurring(series.id);
        y += px(28);
    }

    // Merchant history.
    if st.merchant_count > 1 && t.categorizable {
        avg := st.merchant_total / max(st.merchant_count, 1);
        section("At this merchant", *y, x, w, tprint("since %", format_date(st.merchant_first)));
        summary := tprint("% purchases · % spent · % average", format_grouped(st.merchant_count), format_money(st.merchant_total), format_money(avg));
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(x, y, w, px(18)), summary, theme.text_secondary);
        y += px(24);
        for k: 0..st.merchant_recent_count - 1 {
            other := *store.transactions[st.merchant_recent[k]];
            row := rect(x, y, w, px(22));
            rid := ui_id("merchant-row", k);
            rw := ui_widget(rid);
            io := ui_interact(rid, row);
            if io.hovered ui.cursor = .HAND;
            ui_animate(*rw.hover, ifx io.hovered then 1.0 else 0.0, 24);
            current := st.merchant_recent[k] == index;
            if current || rw.hover > 0 draw_rect(snap(rect(row.x - px(6), row.y, row.w + px(12), row.h)), ifx current then theme.accent_wash else color_with_alpha(theme.hover, rw.hover * 0.6), px(2));
            draw_text_in_rect(fonts.regular, px(theme.font_size_label), row, format_weekday_date(other.day, app.today), ifx current then theme.text else theme.text_secondary, .LEFT, .{tabular = true});
            draw_amount(row, other.amount, .RIGHT, px(theme.font_size_label));
            if io.clicked && !current show_transactions(select_id = other.id);
            y += px(22);
        }
        y += px(8);
    }

    y += px(10);
    st.scroll.content = y - top + px(14);
    pop_opacity();
    pop_clip();
    ui_scroll_draw(*st.scroll);
    return close;
}

// The inspector for several transactions at once (`indices`, two or more):
// what they add up to, the categories and tags they carry, and moving them
// all to one category or adding a tag to them all.
// Returns true when the close button was pressed.
draw_bulk_inspector :: (r: Rect, st: *Inspector_State, indices: [] s32) -> bool {
    close := false;
    content, header := panel_begin(r, "Selection");
    close_r := cut_right(*header, px(26));
    if ui_icon_button("close##bulk", .CLOSE, close_r, "Clear selection (Esc)") close = true;
    if !indices.count return close;

    if !st.bulk {
        st.bulk = true;
        set_string(*st.shown_id, "");
        st.switch_t = 0;
        st.scroll = .{};
        st.bulk_tag_input.count = 0;
    }
    ui_animate(*st.switch_t, 1, 14);

    // What they add up to, and the categories and tags on them.
    money_in, money_out: s64;
    categorizable := 0;
    category_counts := NewArray(store.categories.count + 1, int,, temp);   // By category + 1: [0] is uncategorised.
    first_day, last_day := store.transactions[indices[0]].day, store.transactions[indices[0]].day;
    held := 0;
    full := 0;   // Already carrying as many tags as Up allows.
    accounts: s32 = -1;
    several_accounts := false;
    tag_counts := NewArray(store.tags.count, int,, temp);
    for indices {
        t := *store.transactions[it];
        if t.amount > 0 money_in += t.amount; else money_out -= t.amount;
        first_day = min(first_day, t.day);
        last_day  = max(last_day, t.day);
        if t.status == .HELD held += 1;
        if t.tag_count >= MAX_TAGS full += 1;
        if accounts < 0 accounts = t.account;
        else if accounts != t.account several_accounts = true;
        for i: 0..t.tag_count - 1 tag_counts[t.tags[i]] += 1;
        if t.categorizable {
            categorizable += 1;
            category_counts[t.category + 1] += 1;
        }
    }

    view := rect_inset_xy(content, 0, 0);
    offset := ui_scroll_area(ui_id("bulk-scroll"), view, *st.scroll, st.scroll.content);
    push_clip(view);
    push_opacity(0.3 + 0.7 * st.switch_t);
    pad := px(16);
    x := view.x + pad;
    w := view.w - 2 * pad - px(6);
    y := view.y + px(14) - offset + px(6) * (1 - st.switch_t);
    top := y;

    // Heading: how many, and their net.
    draw_text_in_rect(fonts.semibold, px(16), rect(x, y, w, px(22)), format_count(indices.count, "transaction", "transactions"), theme.text);
    y += px(26);
    net := money_in - money_out;
    draw_text_in_rect(fonts.numeric, px(28), rect(x, y, w, px(34)), format_money(net, .ALWAYS), ifx net > 0 then theme.positive else theme.text, .LEFT, .{tabular = true});
    y += px(36);
    when := ifx first_day == last_day then format_weekday_date(first_day, app.today) else tprint("% – %", format_date_column(first_day), format_date(last_day));
    if held when = tprint("% · % held", when, held);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(x, y, w, px(16)), when, theme.text_muted);
    y += px(26);

    // Category: one for them all. The list counts how many are in each now.
    uncategorizable := indices.count - categorizable;
    section("Category", *y, x, w, ifx uncategorizable && categorizable then tprint("% of % can be categorised", categorizable, indices.count) else "");
    if categorizable {
        items, map := category_picker_items();
        shared := -1;   // The item they all share, if they do.
        kinds := 0;
        for * items {
            if map[it_index] == -3 continue;
            n := category_counts[map[it_index] + 1];
            if !n continue;
            it.detail = format_grouped(n);
            kinds += 1;
            if n == categorizable shared = it_index;
        }
        picked := shared;
        prefix := ifx shared < 0 then tprint("% categories", kinds) else "";
        if ui_dropdown("category##bulk", rect(x, y, w, px(30)), items, *picked, prefix, popup_width = w) {
            if picked >= 0 && picked < map.count && map[picked] != -3 {
                category := map[picked];
                moved := 0;
                sync_batch_begin();
                for indices {
                    t := *store.transactions[it];
                    if !t.categorizable || t.category == category continue;
                    sync_set_category(it, category);
                    moved += 1;
                }
                name := ifx category >= 0 then store.categories[category].name else "Uncategorised";
                message := ifx category >= 0 then tprint("% categorised as %.", format_count(moved, "transaction", "transactions"), name)
                           else tprint("Took % out of their categories.", format_count(moved, "transaction", "transactions"));
                if uncategorizable message = tprint("% % skipped: not categorisable.", message, uncategorizable);
                sync_batch_end(message, ifx category >= 0 then tprint("Not all categorised as %", name) else "Not all taken out of their categories");
            }
        }
        y += px(30);
        y += px(6);
        hint := ifx uncategorizable then "Transfers, interest and payments to people stay as they are." else "Applies to all of them.";
        draw_text_fit(fonts.regular, px(theme.font_size_small), rect(x, y, w, px(14)), hint, theme.text_faint);
        y += px(20);
    } else {
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(x, y, w, px(18)), "None can be categorised: transfers, interest and payments to people aren't.", theme.text_muted);
        y += px(26);
    }

    // Tags: those already on some of them, then adding one to all.
    section("Tags", *y, x, w, "on the selected transactions");
    chip_x := x;
    to_remove: s32 = -1;
    on_all := NewArray(store.tags.count, bool,, temp);
    any_tags := false;
    for count, tag: tag_counts {
        if !count continue;
        any_tags = true;
        on_all[tag] = count == indices.count;
        label := store.tags[tag].label;
        detail := ifx count == indices.count then "all" else tprint("% of %", count, indices.count);
        if tag_chip(*chip_x, *y, x, w, cast(s32) tag, tprint("Remove \"%\" from %", label, ifx count == indices.count then "all of them" else format_count(count, "transaction", "transactions")), detail) to_remove = cast(s32) tag;
    }
    if any_tags y += px(32);
    if to_remove >= 0 {
        label := copy_string(store.tags[to_remove].label,, temp);
        removed := 0;
        sync_batch_begin();
        for indices if txn_has_tag(*store.transactions[it], to_remove) { sync_remove_tag(it, to_remove); removed += 1; }
        sync_batch_end(tprint("Removed \"%\" from %.", label, format_count(removed, "transaction", "transactions")), tprint("\"%\" not removed from all", label));
    }

    add_r := rect(x, y, w, px(30));
    button_r := cut_right(*add_r, px(64));
    cut_right(*add_r, px(6));
    changed, submitted := ui_text_input("tag##bulk", add_r, *st.bulk_tag_input, "Add a tag to all…", .CLEARABLE, max_length = 60);
    label := trim(buffer_string(*st.bulk_tag_input));
    adding := "";
    if ui_button("Add##bulk-tag", button_r, .SECONDARY, .ADD, enabled = label.count > 0) || (submitted && label.count) adding = label;
    y += px(36);
    suggested := tag_suggestions(x, *y, w, label, on_all);
    if suggested >= 0 adding = store.tags[suggested].label;
    if full {
        draw_text_fit(fonts.regular, px(theme.font_size_small), rect(x, y, w, px(14)), tprint("% already % % tags, the most Up allows.", format_count(full, "transaction", "transactions"), ifx full == 1 then "has" else "have", MAX_TAGS), theme.text_faint);
        y += px(20);
    }
    if adding.count {
        adding = copy_string(adding,, temp);
        tag := store_find_tag(*store, adding);
        added, had, skipped := 0, 0, 0;
        sync_batch_begin();
        for indices {
            t := *store.transactions[it];
            if tag >= 0 && txn_has_tag(t, tag) { had += 1; continue; }
            if t.tag_count >= MAX_TAGS { skipped += 1; continue; }
            sync_add_tag(it, adding);
            added += 1;
        }
        message := tprint("Added \"%\" to %.", adding, format_count(added, "transaction", "transactions"));
        if had     message = tprint("% % already had it.", message, had);
        if skipped message = tprint("% % skipped: no room for more tags.", message, skipped);
        if !added && !had { app_toast(.ERROR, message); message = ""; }   // Nothing to wait for.
        sync_batch_end(message, tprint("\"%\" not added to all", adding));
        st.bulk_tag_input.count = 0;
    }

    // Summary.
    section("Summary", *y, x, w);
    field("Money in", ifx money_in then format_money(money_in) else "—", *y, x, w, false, ifx money_in then theme.positive else 0);
    field("Money out", ifx money_out then format_money(money_out) else "—", *y, x, w);
    field("Account", ifx several_accounts then "Several" else account_name(*store, accounts), *y, x, w);
    y += px(8);

    // Saving them: as a PDF two ways, or as a CSV for a spreadsheet. The
    // Save dialog blocks until it closes; the frame carries on after.
    section("Export", *y, x, w);
    buttons := rect(x, y, w, px(30));
    statement_r := cut_left(*buttons, (w - px(8)) * 0.5);
    cut_left(*buttons, px(8));
    if ui_button("Statement PDF##bulk-print", statement_r, .SECONDARY, .PRINT, tooltip = "One list of them all: date, description and amount, with the total") save_statement_pdf(indices);
    if ui_button("Full pages PDF##bulk-print", buttons, .SECONDARY, .PRINT, tooltip = "Each on its own page, as when saving one transaction") save_transactions_pdf(indices);
    y += px(38);
    if ui_button("Spreadsheet CSV##bulk-csv", rect(x, y, w, px(30)), .SECONDARY, .DOWNLOAD, tooltip = "A row for each, with everything Up says about it, for a spreadsheet or accounting software") save_transactions_csv(indices);
    y += px(36);
    draw_text_fit(fonts.regular, px(theme.font_size_small), rect(x, y, w, px(14)), "Oldest first, in one file.", theme.text_faint);
    y += px(26);
    draw_text_fit(fonts.regular, px(theme.font_size_small), rect(x, y, w, px(14)), tprint("% to add or remove · Shift+click for a run · Esc to clear", MOD_CLICK), theme.text_faint);
    y += px(20);

    y += px(10);
    st.scroll.content = y - top + px(14);
    pop_opacity();
    pop_clip();
    ui_scroll_draw(*st.scroll);
    return close;
}

#scope_file

section :: (title: string, y: *float, x: float, w: float, detail := "") {
    ui_divider(x - px(16), y.*, w + px(38), theme.divider);
    y.* += px(12);
    tw := draw_caps(rect(x, y.*, w, px(14)), title, theme.text_muted);
    if detail.count draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(x + tw + px(8), y.*, w, px(14)), detail, theme.text_faint);
    y.* += px(20);
}

field :: (label: string, value: string, y: *float, x: float, w: float, mono := false, color: Color = 0) {
    if !value.count return;
    draw_field(rect(x, y.*, w, px(22)), label, value, mono, color);
    y.* += px(22);
}

// A tag as a chip with a remove button, flowing along a row from `chip_x`
// and wrapping below `y`. `detail` is shown faintly after the label.
// Returns true when the remove button was clicked.
tag_chip :: (chip_x: *float, y: *float, x: float, w: float, tag: s32, tooltip: string, detail := "") -> bool {
    label := store.tags[tag].label;
    size := px(theme.font_size_label);
    tw := measure_text(fonts.regular, size, label);
    dw := ifx detail.count then measure_text(fonts.regular, size, detail) + px(14) else 0.0;
    cw := tw + dw + px(34);
    if chip_x.* + cw > x + w && chip_x.* > x { chip_x.* = x; y.* += px(28); }
    chip := snap(rect(chip_x.*, y.*, cw, px(24)));
    cid := ui_id("tag-chip", tag + 1);
    cwid := ui_widget(cid);
    x_r := rect(chip.x + chip.w - px(22), chip.y, px(22), chip.h);
    xio := ui_interact(ui_id_combine(cid, 1), x_r);
    if xio.hovered ui.cursor = .HAND;
    ui_animate(*cwid.hover, ifx xio.hovered then 1.0 else 0.0, 24);
    draw_rect_outline(chip, theme.raised, theme.border_strong, hairline(), px(3));
    draw_icon(.TAG, chip.x + px(10), chip.y + chip.h * 0.5, px(9), theme.text_muted);
    draw_text_in_rect(fonts.regular, size, rect(chip.x + px(18), chip.y, tw + px(2), chip.h), label, theme.text);
    if detail.count draw_text_in_rect(fonts.regular, size, rect(chip.x + px(18) + tw + px(6), chip.y, dw - px(14), chip.h), detail, theme.text_muted, .LEFT, .{tabular = true});
    if cwid.hover > 0 draw_rect(snap(rect_inset(x_r, px(3))), color_with_alpha(theme.hover, cwid.hover), px(2));
    draw_icon_in(.CLOSE, x_r, px(8), color_lerp(theme.text_muted, theme.danger, cwid.hover));
    ui_tooltip(ui_id_combine(cid, 1), xio.hovered, tooltip);
    chip_x.* += cw + px(6);
    return xio.clicked;
}

// Existing tags that match what is typed (or the most used ones), leaving
// out those marked in `skip`. Advances `y` past them when there are any.
// Returns the tag clicked, or -1.
tag_suggestions :: (x: float, y: *float, w: float, typed: string, skip: [] bool) -> s32 {
    needle := to_lower_temp(typed);
    suggestions: [..] s32;
    suggestions.allocator = temp;
    for tag, ti: store.tags {
        if ti < skip.count && skip[ti] continue;
        if needle.count && !text_contains(tag.label, needle) continue;
        array_add(*suggestions, cast(s32) ti);
    }
    quick_sort(suggestions, (a: s32, b: s32) -> int {
        ca := ifx a < analytics.tags.count then analytics.tags[a].count else 0;
        cb := ifx b < analytics.tags.count then analytics.tags[b].count else 0;
        return cb - ca;
    });
    if !suggestions.count return -1;
    clicked: s32 = -1;
    sx := x;
    shown := 0;
    for suggestions {
        if shown >= 5 break;
        label := store.tags[it].label;
        sw := measure_text(fonts.regular, px(theme.font_size_label), label) + px(16);
        if sx + sw > x + w break;
        sr := snap(rect(sx, y.*, sw, px(22)));
        sid := ui_id("tag-suggest", it + 1);
        swid := ui_widget(sid);
        io := ui_interact(sid, sr);
        if io.hovered ui.cursor = .HAND;
        ui_animate(*swid.hover, ifx io.hovered then 1.0 else 0.0, 24);
        draw_rect_outline(sr, color_with_alpha(theme.hover, swid.hover), color_lerp(theme.border, theme.border_strong, swid.hover), hairline(), px(3));
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), sr, label, color_lerp(theme.text_muted, theme.text, swid.hover), .CENTER);
        if io.clicked clicked = it;
        sx += sw + px(6);
        shown += 1;
    }
    y.* += px(30);
    return clicked;
}

update_merchant :: (st: *Inspector_State, index: s32) {
    key := hash_key(store.version, cast(u64) index);
    if st.merchant_key == key return;
    st.merchant_key = key;
    t := *store.transactions[index];
    st.merchant_count = 0;
    st.merchant_total = 0;
    st.merchant_first = t.day;
    st.merchant_recent_count = 0;
    for * other, i: store.transactions {
        if other.description != t.description || other.amount >= 0 || is_transfer(other) continue;
        st.merchant_count += 1;
        st.merchant_total -= other.amount;
        st.merchant_first = min(st.merchant_first, cast(s64) other.day);
        if st.merchant_recent_count < st.merchant_recent.count {
            st.merchant_recent[st.merchant_recent_count] = cast(s32) i;
            st.merchant_recent_count += 1;
        }
    }
}
