// Transactions: find, compare and fix individual transactions.
//
// Toolbar filters (search, period, account, category, tag, status, direction,
// own transfers) narrow the list. The search also offers matching merchants as you type;
// picking one pins it as a pill in the field (several pills: any of them). The strip under
// it sums what is shown. Sorted by date the list is grouped by day, each day's header
// carrying its money in and out.
// Selecting a row opens the inspector on the right, where the category and
// tags can be changed. Ctrl+click (or Shift+click for a run of rows) chooses
// several; the inspector then sums them up, and moves them to one category
// or tags them all at once.

Transactions_State :: struct {
    search:    Text_Buffer;
    merchants: [..] string;   // Merchant pills in the search (owned copies); a transaction matches any one.
    period:    int;
    account:   int;
    category:  int;
    status:    int;   // 0 all, 1 held, 2 settled
    direction: int;   // 0 all, 1 in, 2 out
    hide_transfers: bool;   // Leave out money moved between my own accounts.
    tag:       s32 = -1;   // Tag index; -1 all, -2 untagged.
    custom:    Period;     // A period picked elsewhere (a month, a chart bar).
    has_custom: bool;

    table:     Table_State;
    rows:      [..] Txn_Row;
    rows_key:  u64;
    totals:    Flow_Totals;
    held_count: int;
    held_total: s64;
    matched:   int;

    selected_id:  string;
    picked:       [..] string;   // Ids of the transactions chosen together: none, or two or more.
    focus_search: bool;
    suggest:      [..] s32;   // Merchants offered under the search, as merchant_index rows.
    suggest_key:  u64;
    suggest_dismissed: bool;  // Escape closed the list; it comes back with the next edit.
    inspector:    Inspector_State;
    inspector_t:  float;
    initialized:  bool;
}

Txn_Row :: struct {
    header:    bool;
    txn:       s32 = -1;
    day:       s64;
    count:     s32;
    money_in:  s64;
    money_out: s64;
    picked:    bool;
}

COL_WHEN     :: 0;
COL_DESC     :: 1;
COL_CATEGORY :: 2;
COL_TAGS     :: 3;
COL_ACCOUNT  :: 4;
COL_STATUS   :: 5;
COL_AMOUNT   :: 6;

TXN_COLUMNS :: Column.[
    .{"Date",        114, .LEFT,  true, 0},
    .{"Description", 0,   .LEFT,  true, 0},
    .{"Category",    184, .LEFT,  true, 660},
    .{"Tags",        124, .LEFT,  false, 1240},
    .{"Account",     128, .LEFT,  true, 1080},
    .{"Status",      84,  .LEFT,  true, 780},
    .{"Amount",      116, .RIGHT, true, 0},
];

TXN_SEARCH :: "search##txn";

// Shows the transactions page with filters that pick out one set.
CUSTOM_PERIOD :: PERIOD_LABELS.count;

show_transactions :: (category := -1, period := 0, status := 0, tag: s32 = -1, select_id := "", account := -1, custom := Period.{}, search := "", merchant := "") {
    st := *app.txn;
    buffer_set(*st.search, search);
    clear_merchants(st);
    if merchant.count pin_merchant(st, merchant);
    items, map := category_filter_items();
    st.category = ifx category == -1 then 0 else index_of_value(map, cast(s32) category);
    st.period = period;
    if custom.last != 0 {
        st.custom = custom;
        st.has_custom = true;
        st.period = CUSTOM_PERIOD;
    }
    st.status = status;
    st.direction = 0;
    st.hide_transfers = false;
    st.tag = tag;
    acct_items, acct_map := account_filter_items();
    st.account = ifx account >= 0 then index_of_value(acct_map, cast(s32) account) else 0;
    if select_id.count { set_string(*st.selected_id, select_id); clear_picked(st); }
    st.rows_key = 0;
    st.table.scroll = .{};
    select_page(.TRANSACTIONS);
}

draw_transactions_page :: (r_in: Rect) {
    st := *app.txn;
    if !st.initialized {
        st.initialized = true;
        st.table.sort_column = COL_WHEN;
        st.table.sort_desc = true;
    }
    r := r_in;

    // Summary of what is shown on top, the filters under it. The figures follow the filters, so
    // the strip's place is taken now and it is drawn once the rows are rebuilt.
    cut_top(*r, px(10));
    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));

    // Filters: search and the pickers on the first row, the toggles and the count on the second.
    bar := toolbar_rect(*r, 2);
    row1 := cut_top(*bar, px(TOOLBAR_ROW));
    cut_top(*bar, px(TOOLBAR_ROW_GAP));
    row2 := cut_top(*bar, px(TOOLBAR_ROW));
    if st.focus_search {
        st.focus_search = false;
        ui_take_focus(ui_id(TXN_SEARCH), true);
    }
    changed := false;

    controls := row1;
    // The search takes what the dropdowns leave; in a narrow window they give up width before it does.
    dropdowns_w := px(150 + 170 + 190 + 160);
    gaps_w := px(8 + 6 * 3);
    search_min := px(240);
    fit := clamp((controls.w - search_min - gaps_w) / dropdowns_w, 0.6, 1.0);
    search_r := cut_left(*controls, max(controls.w - dropdowns_w * fit - gaps_w, search_min));
    if draw_search(st, search_r) changed = true;
    cut_left(*controls, px(8));
    period_items := NewArray(PERIOD_LABELS.count + ifx st.has_custom then 1 else 0, Dropdown_Item,, temp);
    for PERIOD_LABELS period_items[it_index].label = it;
    if st.has_custom period_items[CUSTOM_PERIOD].label = custom_period_label(st.custom);
    if st.period >= period_items.count st.period = 0;
    if ui_dropdown("period##txn", cut_left(*controls, px(150) * fit), period_items, *st.period, popup_width = px(220)) changed = true;
    cut_left(*controls, px(6));
    acct_items, acct_map := account_filter_items();
    if ui_dropdown("account##txn", cut_left(*controls, px(170) * fit), acct_items, *st.account) changed = true;
    cut_left(*controls, px(6));
    cat_items, cat_map := category_filter_items();
    st.category = clamp(st.category, 0, cat_items.count - 1);
    if ui_dropdown("category##txn", cut_left(*controls, px(190) * fit), cat_items, *st.category, popup_width = px(260)) changed = true;
    cut_left(*controls, px(6));
    tag_items, tag_map := tag_filter_items();
    tag_index := index_of_value(tag_map, st.tag);
    if tag_map[tag_index] != st.tag { st.tag = -1; st.rows_key = 0; }   // The tag is gone.
    if ui_dropdown("tag##txn", cut_left(*controls, px(160) * fit), tag_items, *tag_index, popup_width = px(240)) {
        st.tag = tag_map[tag_index];
        changed = true;
    }

    controls = row2;
    count_w := px(150);
    count_r := cut_right(*controls, count_w);
    status_options := string.["All", "Held", "Settled"];
    if ui_segmented("status##txn", cut_left(*controls, ui_segmented_width(status_options)), status_options, *st.status) changed = true;
    cut_left(*controls, px(6));
    direction_options := string.["In & out", "In", "Out"];
    if ui_segmented("direction##txn", cut_left(*controls, ui_segmented_width(direction_options)), direction_options, *st.direction) changed = true;
    cut_left(*controls, px(10));
    transfers_label := "Hide transfers##txn";
    transfers_w := px(22 + 8) + measure_text(fonts.regular, px(theme.font_size_body), display_text(transfers_label));
    if ui_checkbox(transfers_label, cut_left(*controls, transfers_w), *st.hide_transfers) changed = true;
    cut_left(*controls, px(10));
    filtered := st.search.count > 0 || st.merchants.count > 0 || st.period != 0 || st.account != 0 || st.category != 0 || st.status != 0 || st.direction != 0 || st.tag != -1 || st.hide_transfers;
    if filtered {
        if ui_button("Clear##txn-filters", cut_left(*controls, px(70)), .GHOST, .CLOSE) {
            st.search.count = 0;
            clear_merchants(st);
            st.period = 0; st.account = 0; st.category = 0; st.status = 0; st.direction = 0; st.tag = -1;
            st.hide_transfers = false;
            changed = true;
        }
        filtered = st.search.count > 0 || st.merchants.count > 0 || st.period != 0 || st.account != 0 || st.category != 0 || st.status != 0 || st.direction != 0 || st.tag != -1 || st.hide_transfers;
    }
    if changed st.table.scroll.target = 0;

    rebuild_rows(st, acct_map, cat_map);

    count_text := ifx filtered then tprint("% of %", format_grouped(st.matched), format_grouped(store.transactions.count)) else tprint("% transactions", format_grouped(store.transactions.count));
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), count_r, count_text, theme.text_muted, .RIGHT, .{tabular = true});

    loading := sync.phase == .LOADING && !store.transactions.count;
    t := st.totals;
    net := t.money_in - t.money_out;
    outgoing := 0;
    for st.rows if !it.header && store.transactions[it.txn].amount < 0 outgoing += 1;
    average_out := ifx outgoing then t.money_out / outgoing else 0;
    largest := ifx t.largest_out_index >= 0 then store.transactions[t.largest_out_index].description else "";
    metrics := Metric.[
        .{label = "Transactions", value = format_grouped(st.matched), detail = ifx filtered then "matching the filters" else "all loaded", loading = loading},
        .{label = "Money in", value = format_money(t.money_in), value_color = ifx t.money_in > 0 then theme.positive else 0, detail = ifx settings.exclude_transfers then "excl. own transfers" else "incl. own transfers", loading = loading},
        .{label = "Money out", value = format_money(t.money_out), detail = ifx settings.exclude_transfers then "excl. own transfers" else "incl. own transfers", loading = loading, roll_up = false},
        .{label = "Net", value = format_money(net, .ALWAYS), value_color = ifx net > 0 then theme.positive else 0, detail = "in minus out", loading = loading},
        .{label = "Average out", value = format_money(average_out), detail = tprint("over % payments", format_grouped(outgoing)), loading = loading},
        .{label = "Largest out", value = format_money(t.largest_out), detail = largest, loading = loading},
        .{label = "On hold", value = format_money(-st.held_total), value_color = ifx st.held_count then theme.held else 0, detail = format_count(st.held_count, "transaction", "transactions"), loading = loading},
    ];
    draw_metric_strip(strip, metrics, "txn-metrics");

    // Table, with the inspector beside it when a row is selected (or several are).
    multi := st.picked.count > 0;
    selected_txn: s32 = -1;
    if !multi && st.table.selected >= 0 && st.table.selected < st.rows.count && !st.rows[st.table.selected].header selected_txn = st.rows[st.table.selected].txn;
    ui_animate(*st.inspector_t, ifx selected_txn >= 0 || multi then 1.0 else 0.0, 16);
    inspector_w := px(400) * ease_out_cubic(st.inspector_t);
    table_area := r;
    inspector_area: Rect;
    if inspector_w > 1 {
        inspector_area = cut_right(*table_area, inspector_w);
        cut_right(*table_area, px(8) * st.inspector_t);
    }

    body := appear_begin(table_area, 0);
    content, header := panel_begin(body, "Transactions", tprint("sorted by %", to_lower_temp(TXN_COLUMNS[max(st.table.sort_column, 0)].title)));
    t_rect := rect_inset_xy(content, 0, 0);
    t_rect.h -= hairline();
    tbl: Data_Table;
    // With several chosen, each marks its own row (below) instead of the one highlight.
    was_selected := st.table.selected;
    table_begin(*tbl, "txn-table", t_rect, TXN_COLUMNS, *st.table, st.rows.count, keyboard = true, highlight = !multi);
    if tbl.sort_changed st.rows_key = 0;

    // Moving with the keys goes back to one transaction.
    if tbl.selection_changed && multi clear_picked(st);
    // Headers aren't selectable: step over them, the way the selection was moving
    // (down when there's nothing above, as for the first day's header).
    if tbl.selection_changed && st.table.selected >= 0 && st.table.selected < st.rows.count && st.rows[st.table.selected].header {
        if st.table.selected < was_selected && st.table.selected > 0 st.table.selected -= 1;
        else if st.table.selected + 1 < st.rows.count st.table.selected += 1;
    }
    if st.table.selected >= 0 && st.table.selected < st.rows.count {
        row := st.rows[st.table.selected];
        if !row.header set_string(*st.selected_id, store.transactions[row.txn].id);
    }
    if key_pressed(.ESCAPE) && (st.table.selected >= 0 || st.picked.count) && !ui.popup && !ui.text_focus_prev {
        st.table.selected = -1;
        set_string(*st.selected_id, "");
        clear_picked(st);
        input.key_pressed[Key.ESCAPE] = false;
    }
    cursor := st.table.selected;   // Before this frame's click moves it.

    if loading {
        table_skeleton(*tbl, 18);
    } else if st.rows.count == 0 {
        table_end(*tbl);
        if store.transactions.count draw_empty_state(t_rect, "No transactions match these filters", "Clear a filter or widen the period.", .FILTER);
        else draw_empty_state(t_rect, "No transactions yet", "", .INFO);
    }
    if !loading && st.rows.count {
        for i: tbl.first..tbl.last {
            row_data := *st.rows[i];
            row := table_row(*tbl, i);
            if row_data.header {
                draw_day_header(*tbl, row, row_data);
                continue;
            }
            if row_data.picked {
                mark := snap(rect(row.x, row.y, tbl.body.w, row.h - hairline()));
                draw_rect(mark, theme.accent_wash);
                draw_rect(snap(rect(mark.x, mark.y, px(2), mark.h)), theme.accent);
            }
            draw_txn_row(*tbl, row, row_data.txn);
        }
        table_end(*tbl);
        if tbl.clicked >= 0 && !st.rows[tbl.clicked].header pick_on_click(st, tbl.clicked, cursor);
    } else if loading {
        table_end(*tbl);
    }
    appear_end();

    if inspector_w > 1 {
        push_opacity(st.inspector_t);
        closed := false;
        if st.picked.count {
            picked: [..] s32;
            picked.allocator = temp;
            for st.rows if it.picked array_add(*picked, it.txn);
            closed = draw_bulk_inspector(inspector_area, *st.inspector, picked);
        } else {
            closed = draw_inspector(inspector_area, *st.inspector, selected_txn);
        }
        if closed {
            st.table.selected = -1;
            set_string(*st.selected_id, "");
            clear_picked(st);
        }
        pop_opacity();
    }
}

pin_merchant :: (st: *Transactions_State, name: string) {
    if !merchant_pinned(st, name) array_add(*st.merchants, copy_string(name));
    st.search.count = 0;
    if ui.popup == search_list_id() ui_close_popup();
}

clear_merchants :: (st: *Transactions_State) {
    for st.merchants free(it);
    st.merchants.count = 0;
}

clear_picked :: (st: *Transactions_State) {
    for st.picked free(it);
    st.picked.count = 0;
    for * st.rows it.picked = false;
}

#scope_file

// The search field: free text that filters as you type, after it any merchant pills. While
// typing, the merchants whose names match are offered underneath; Down/Up and Enter, or a
// click, pin one. Backspace in the empty field takes the last pill off again.
draw_search :: (st: *Transactions_State, r: Rect) -> changed: bool {
    id := ui_id(TXN_SEARCH);
    list_id := search_list_id();
    changed := false;

    // The field would take these keys itself, so the list and the pills see them first.
    if ui.focus == id {
        if ui.popup == list_id {
            hl := ui.popup_highlight;
            if key_pressed(.DOWN) { hl = min(hl + 1, st.suggest.count - 1); input.key_pressed[Key.DOWN] = false; }
            if key_pressed(.UP)   { hl = max(hl - 1, -1); input.key_pressed[Key.UP] = false; }
            ui.popup_highlight = hl;
            if key_pressed(.ENTER) && hl >= 0 && hl < st.suggest.count {
                input.key_pressed[Key.ENTER] = false;
                pin_merchant(st, merchant_index.names[st.suggest[hl]]);
                changed = true;
            }
            if key_pressed(.ESCAPE) {
                input.key_pressed[Key.ESCAPE] = false;
                ui_close_popup();
                st.suggest_dismissed = true;
            }
        }
        if !st.search.count && st.merchants.count && key_pressed(.BACKSPACE) {
            input.key_pressed[Key.BACKSPACE] = false;
            unpin_merchant(st, st.merchants.count - 1);
            changed = true;
        }
    }

    // A pill's x sits inside the field, so it must interact before the field does.
    pills := layout_pills(st, r);
    removed := -1;
    over_close := false;
    for p, k: pills.rects {
        cid := pill_id(id, pills.first + k);
        cw := ui_widget(cid);
        io := ui_interact(cid, pill_close_rect(p));
        ui_animate(*cw.hover, ifx io.hovered then 1.0 else 0.0, 22);
        if io.hovered over_close = true;
        if io.pressed {
            if ui.focus != id { ui_take_focus(id); ui_widget(id).t = 1; }   // Gained by mouse: don't select all.
            ui.focus_claimed = true;
        }
        if io.clicked removed = pills.first + k;
    }

    edited, _, cleared := ui_text_input(TXN_SEARCH, r, *st.search, "Search merchants, descriptions, notes, tags, amounts…", .SEARCH, lead = pills.lead);
    if edited { changed = true; st.suggest_dismissed = false; }
    if cleared && st.merchants.count { clear_merchants(st); changed = true; }
    if removed >= 0 { unpin_merchant(st, removed); changed = true; }
    if over_close ui.cursor = .HAND;

    if removed >= 0 || cleared {
        pills = layout_pills(st, r);
        ui.animating = true;   // The text moves over next frame.
    }
    if pills.first > 0 draw_chip(pills.more.x, pills.more.y + pills.more.h * 0.5, tprint("+%", pills.first), theme.accent);
    for p, k: pills.rects draw_pill(p, st.merchants[pills.first + k], ui_widget(pill_id(id, pills.first + k)).hover);

    // The suggestions follow the text; the list shows while the field has the keyboard.
    update_merchant_index();
    update_suggestions(st, to_lower_temp(trim(buffer_string(*st.search))));
    want := ui.focus == id && st.suggest.count > 0 && !st.suggest_dismissed && (ui.popup == 0 || ui.popup == list_id);
    if want && ui.popup != list_id {
        // A click in the field closes the list on its way through (the field is its anchor):
        // put it straight back rather than opening it again.
        again := ui.popup == 0 && ui.popup_opened == ui.frame;
        ui_open_popup(list_id, r);
        if again ui.popup_t = 1;
    } else if !want && ui.popup == list_id {
        ui_close_popup();
    }
    if ui.popup == list_id && draw_suggestions(st, list_id, r) {
        changed = true;
        ui.animating = true;
    }
    return changed;
}

search_list_id :: () -> UI_Id { return ui_id_combine(ui_id(TXN_SEARCH), 0x5EC7); }

pill_id :: (search: UI_Id, index: int) -> UI_Id { return ui_id_combine(search, cast(u64) (0x9111 + index)); }

Pill_Layout :: struct {
    rects: [] Rect;   // The pills shown: the newest, as many as fit.
    first: int;       // Index of the first one shown; those before it fold into a "+N" chip.
    more:  Rect;
    lead:  float;     // Room they take before the text.
}

// The pills take at most about half the field; the oldest give way first.
layout_pills :: (st: *Transactions_State, field: Rect) -> Pill_Layout {
    out: Pill_Layout;
    n := st.merchants.count;
    if !n return out;
    gap := px(4);
    room := field.w * 0.55;
    used := 0.0;
    first := n;
    while first > 0 {
        w := min(pill_width(st.merchants[first - 1]), room) + gap;
        more := ifx first > 1 then chip_width(tprint("+%", first - 1)) + gap else 0.0;
        if first < n && used + w + more > room break;   // The newest always shows.
        used += w;
        first -= 1;
    }
    out.first = first;

    b := snap(field);
    x0 := b.x + px(9 + 18);   // After the field's padding and magnifier.
    x := x0;
    cy := b.y + b.h * 0.5;
    if first > 0 {
        out.more = rect(x, cy - px(9), chip_width(tprint("+%", first)), px(18));
        x += out.more.w + gap;
    }
    h := px(PILL_HEIGHT);
    out.rects = NewArray(n - first, Rect,, temp);
    for i: first..n - 1 {
        w := min(pill_width(st.merchants[i]), room);
        out.rects[i - first] = rect(x, cy - h * 0.5, w, h);
        x += w + gap;
    }
    out.lead = x - x0 + px(2);
    return out;
}

// Returns true when a merchant was picked.
draw_suggestions :: (st: *Transactions_State, id: UI_Id, anchor: Rect) -> bool {
    row_h := px(28);
    head_h := px(26);
    visible, area := ui_popup_begin(id, clamp(anchor.w, px(280), px(440)), head_h + st.suggest.count * row_h + px(6));
    if !visible return false;
    draw_caps(rect(area.x + px(12), area.y + px(2), area.w - px(24), head_h), "Merchants", theme.text_muted);
    picked := -1;
    for s, i: st.suggest {
        row := rect(area.x, area.y + px(2) + head_h + i * row_h, area.w, row_h);
        rid := ui_id_combine(id, cast(u64) i + 1000);
        rw := ui_widget(rid);
        rio := ui_interact(rid, row);
        if rio.hovered { ui.cursor = .HAND; if ui.mouse_moved || rio.pressed ui.popup_highlight = i; }
        if rio.pressed ui.focus_claimed = true;   // The field keeps the keyboard.
        ui_animate(*rw.hover, ifx ui.popup_highlight == i then 1.0 else 0.0, 30);
        if rw.hover > 0 draw_rect(snap(rect_inset_xy(row, px(4), px(1))), color_with_alpha(theme.hover, rw.hover), px(2));
        t := rect_inset_xy(row, px(12), 0);
        dw := draw_text_in_rect(fonts.regular, px(theme.font_size_label), t, format_count(merchant_index.counts[s], "transaction", "transactions"), theme.text_muted, .RIGHT, .{tabular = true});
        t.w -= dw + px(10);
        draw_text_fit(fonts.regular, px(theme.font_size_body), t, merchant_index.names[s], theme.text);
        if rio.clicked picked = s;
    }
    ui_popup_end();
    if picked < 0 return false;
    pin_merchant(st, merchant_index.names[picked]);
    ui.popup_drawn = true;   // Closed on purpose; don't report it as orphaned.
    return true;
}

unpin_merchant :: (st: *Transactions_State, index: int) {
    free(st.merchants[index]);
    array_ordered_remove_by_index(*st.merchants, index);
}

merchant_pinned :: (st: *Transactions_State, name: string) -> bool {
    for st.merchants if it == name return true;
    return false;
}

merchant_pills_hash :: (st: *Transactions_State) -> u64 {
    h: u64 = cast(u64) st.merchants.count;
    for st.merchants h = hash_key(h, hash_key_string(it));
    return h;
}

// Every merchant (a transaction's description) with how many transactions it has.
Merchant_Index :: struct {
    key:    u64;
    names:  [..] string;   // Point into the transactions' storage.
    counts: [..] s32;
}

merchant_index: Merchant_Index;

update_merchant_index :: () {
    m := *merchant_index;
    key := hash_key(store.version, 0x3E7C);
    if m.key == key return;
    m.key = key;
    m.names.count = 0;
    m.counts.count = 0;
    lookup: Table(string, int);
    lookup.allocator = temp;
    for * t: store.transactions {
        if !t.description.count continue;
        found, index := table_find(*lookup, t.description);
        if !found {
            index = m.names.count;
            table_set(*lookup, t.description, index);
            array_add(*m.names, t.description);
            array_add(*m.counts, 0);
        }
        m.counts[index] += 1;
    }
}

MAX_SUGGESTIONS :: 8;

Suggestion :: struct {
    index: s32;
    rank:  s32;
    count: s32;
    name:  string;
}

// Merchants whose names hold the (lower case) text, not already pinned: the name itself first,
// then names starting with it, then those with a word starting with it, then the rest; busiest
// first in each. Text that looks like an amount only offers names that start with it.
update_suggestions :: (st: *Transactions_State, needle: string) {
    key := hash_key(merchant_index.key, hash_key_string(needle), merchant_pills_hash(st));
    if key == st.suggest_key return;
    st.suggest_key = key;
    st.suggest.count = 0;
    if ui.popup == search_list_id() ui.popup_highlight = -1;   // A new list starts with nothing picked.
    if !needle.count return;

    amount := true;
    for 0..needle.count - 1 {
        c := needle[it];
        if !(c >= #char "0" && c <= #char "9") && c != #char "." && c != #char "," && c != #char "$" { amount = false; break; }
    }
    found: [..] Suggestion;
    found.allocator = temp;
    for name, i: merchant_index.names {
        rank := match_rank(name, needle);
        if rank < 0 || (amount && rank > 1) || merchant_pinned(st, name) continue;
        array_add(*found, .{cast(s32) i, cast(s32) rank, merchant_index.counts[i], name});
    }
    quick_sort(found, (a: Suggestion, b: Suggestion) -> int {
        if a.rank != b.rank return a.rank - b.rank;
        if a.count != b.count return b.count - a.count;
        return compare_nocase(a.name, b.name);
    });
    for 0..min(found.count, MAX_SUGGESTIONS) - 1 array_add(*st.suggest, found[it].index);
}

// Where the (lower case) needle falls in hay: 0 the whole of it, 1 at the start, 2 at the start
// of a later word, 3 inside a word, -1 not at all.
match_rank :: (hay: string, needle: string) -> int {
    if hay.count < needle.count return -1;
    best := -1;
    for i: 0..hay.count - needle.count {
        match := true;
        for j: 0..needle.count - 1 {
            h := hay[i + j];
            if h >= #char "A" && h <= #char "Z" h += 32;
            if h != needle[j] { match = false; break; }
        }
        if !match continue;
        if i == 0 return ifx hay.count == needle.count then 0 else 1;
        p := hay[i - 1];
        if !((p >= #char "a" && p <= #char "z") || (p >= #char "A" && p <= #char "Z") || (p >= #char "0" && p <= #char "9")) return 2;
        best = 3;
    }
    return best;
}

// A plain click chooses one transaction; Ctrl+click adds or removes one,
// starting from the one already chosen; Shift+click chooses the run of rows
// from the one already chosen.
pick_on_click :: (st: *Transactions_State, clicked: int, cursor: int) {
    has_cursor := cursor >= 0 && cursor < st.rows.count && !st.rows[cursor].header;
    if ctrl_down() {
        if !st.picked.count && has_cursor set_picked(st, cursor, true);
        set_picked(st, clicked, !st.rows[clicked].picked);
    } else if shift_down() && has_cursor {
        clear_picked(st);
        for min(cursor, clicked)..max(cursor, clicked) if !st.rows[it].header set_picked(st, it, true);
        st.table.selected = cursor;   // Further Shift+clicks run from the same row.
    } else {
        clear_picked(st);
        return;
    }
    settle_picked(st);
}

set_picked :: (st: *Transactions_State, row: int, on: bool) {
    data := *st.rows[row];
    if data.picked == on return;
    data.picked = on;
    id := store.transactions[data.txn].id;
    if on {
        array_add(*st.picked, copy_string(id));
    } else {
        for st.picked if it == id { free(it); array_unordered_remove_by_index(*st.picked, it_index); break; }
    }
}

// One chosen is the ordinary selection, and none is no selection.
settle_picked :: (st: *Transactions_State) {
    if st.picked.count >= 2 return;
    if st.picked.count == 1 {
        set_string(*st.selected_id, st.picked[0]);
        for st.rows if it.picked { st.table.selected = it_index; break; }
    } else {
        set_string(*st.selected_id, "");
        st.table.selected = -1;
    }
    clear_picked(st);
}

draw_day_header :: (t: *Data_Table, row: Rect, data: *Txn_Row) {
    draw_rect(snap(rect(row.x, row.y, t.body.w, row.h)), theme.panel_header);
    inner := rect_inset_xy(row, px(CELL_PAD), 0);
    label := day_label(data.day, app.today);
    w := draw_text_in_rect(fonts.semibold, px(theme.font_size_label), inner, label, theme.text_secondary);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(inner.x + w + px(10), inner.y, px(140), inner.h), format_count(data.count, "transaction", "transactions"), theme.text_muted);
    amount_cell := table_cell(t, row, COL_AMOUNT);
    right := rect(inner.x, inner.y, amount_cell.x + amount_cell.w - inner.x, inner.h);
    size := px(theme.font_size_label);
    text := "";
    if data.money_out text = tprint("out %", format_money(-data.money_out));
    if data.money_in  text = ifx text.count then tprint("in %   %", format_money(data.money_in, .ALWAYS), text) else tprint("in %", format_money(data.money_in, .ALWAYS));
    draw_text_in_rect(fonts.regular, size, right, text, theme.text_muted, .RIGHT, .{tabular = true});
}

draw_txn_row :: (t: *Data_Table, row: Rect, index: s32) {
    txn := *store.transactions[index];
    size := px(theme.font_size_body);

    // Fresh from a refresh: a brief wash that fades.
    age := ui.time - txn.arrived_at;
    if age < 3.0 {
        draw_rect(snap(rect(row.x, row.y, t.body.w, row.h)), color_with_alpha(theme.accent_wash, cast(float) (1 - age / 3.0) * 1.6));
        ui.animating = true;
    }

    when := table_cell(t, row, COL_WHEN);
    baseline := text_baseline_in(fonts.regular, px(theme.font_size_label), when);
    w := draw_text(fonts.regular, px(theme.font_size_label), when.x, baseline, format_date_short(txn.day, app.today), theme.text_secondary, .{tabular = true});
    draw_text(fonts.mono, px(theme.font_size_small), when.x + w + px(8), baseline, format_time(txn.created), theme.text_muted);

    desc := table_cell(t, row, COL_DESC);
    // Narrow table: the status column is gone, so holds show in the description.
    if !table_column_shown(t, COL_STATUS) && txn.status == .HELD {
        cw := draw_chip(desc.x, desc.y + desc.h * 0.5, "Held", theme.held);
        cut_left(*desc, cw + px(8));
    }
    if is_transfer(txn) {
        draw_icon(.SYNC, desc.x + px(6), desc.y + desc.h * 0.5, px(10), theme.text_muted);
        cut_left(*desc, px(18));
    }
    secondary := txn.message;
    if !secondary.count && txn.note.count secondary = txn.note;
    if !secondary.count && txn.has_foreign secondary = format_foreign(txn.foreign_currency, txn.foreign_value);
    main_w := measure_text(fonts.regular, size, txn.description);
    if secondary.count && main_w < desc.w - px(60) {
        draw_text_in_rect(fonts.regular, size, desc, txn.description, theme.text);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(desc.x + main_w + px(10), desc.y, desc.w - main_w - px(10), desc.h), secondary, theme.text_muted);
    } else {
        draw_text_fit(fonts.regular, size, desc, txn.description, theme.text);
    }

    if table_column_shown(t, COL_CATEGORY) draw_category(table_cell(t, row, COL_CATEGORY), txn.category, txn.categorizable);

    if table_column_shown(t, COL_TAGS) && txn.tag_count {
        cell := table_cell(t, row, COL_TAGS);
        label := store.tags[txn.tags[0]].label;
        if txn.tag_count > 1 label = tprint("% +%", label, txn.tag_count - 1);
        draw_icon(.TAG, cell.x + px(5), cell.y + cell.h * 0.5, px(10), theme.text_muted);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(cell.x + px(16), cell.y, cell.w - px(16), cell.h), label, theme.text_secondary);
    }
    if table_column_shown(t, COL_ACCOUNT) draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(t, row, COL_ACCOUNT), account_name(*store, txn.account), theme.text_secondary);
    if table_column_shown(t, COL_STATUS) draw_status(table_cell(t, row, COL_STATUS), txn.status);
    draw_amount(table_cell(t, row, COL_AMOUNT), txn.amount);
}

sort_column_for_compare: int;

rebuild_rows :: (st: *Transactions_State, acct_map: [] s32, cat_map: [] s32) {
    search := to_lower_temp(trim(buffer_string(*st.search)));
    key := hash_key(store.version, cast(u64) st.period, cast(u64) st.account, cast(u64) st.category, cast(u64) st.status, cast(u64) st.direction,
                    cast(u64) (st.table.sort_column + 3), cast(u64) st.table.sort_desc, cast(u64) app.today, cast(u64) (st.tag + 5), cast(u64) settings.exclude_transfers, cast(u64) st.hide_transfers,
                    cast(u64) hash_key_string(search), merchant_pills_hash(st), user_data.excluded_version);
    if key == st.rows_key return;
    st.rows_key = key;

    period, has_period := period_from_index(st.period, app.today);
    if st.period == CUSTOM_PERIOD && st.has_custom { period = st.custom; has_period = true; }
    account := ifx st.account > 0 && st.account < acct_map.count then acct_map[st.account] else -1;
    category := ifx st.category > 0 && st.category < cat_map.count then cat_map[st.category] else -1;

    indices: [..] s32;
    indices.allocator = temp;
    st.totals = .{};
    st.held_count = 0;
    st.held_total = 0;
    for * txn, i: store.transactions {
        if has_period && (txn.day < period.first || txn.day > period.last) continue;
        if account >= 0 && txn.account != account continue;
        if !category_matches(txn, category) continue;
        if st.status == 1 && txn.status != .HELD continue;
        if st.status == 2 && txn.status != .SETTLED continue;
        if st.direction == 1 && txn.amount <= 0 continue;
        if st.direction == 2 && txn.amount >= 0 continue;
        if st.hide_transfers && is_own_transfer(txn) continue;
        if !tag_matches(txn, st.tag) continue;
        if st.merchants.count && !merchant_pinned(st, txn.description) continue;
        if !txn_matches(txn, search) continue;
        array_add(*indices, cast(s32) i);
        if counts_for(txn, account) {
            st.totals.count += 1;
            if txn.amount > 0 st.totals.money_in += txn.amount;
            else {
                st.totals.money_out -= txn.amount;
                if -txn.amount > st.totals.largest_out { st.totals.largest_out = -txn.amount; st.totals.largest_out_index = cast(s32) i; }
            }
        }
        if txn.status == .HELD { st.held_count += 1; st.held_total += txn.amount; }
    }
    st.matched = indices.count;

    column := st.table.sort_column;
    by_date := column == COL_WHEN || column < 0;
    // Search results are usually a few scattered days: list them plainly.
    grouped := by_date && !search.count && !st.merchants.count;
    if !by_date {
        sort_column_for_compare = column;
        quick_sort(indices, (a: s32, b: s32) -> int {
            x := *store.transactions[a];
            y := *store.transactions[b];
            c := 0;
            if sort_column_for_compare == {
                case COL_DESC;     c = compare_nocase(x.description, y.description);
                case COL_CATEGORY; c = compare_nocase(category_name(*store, x.category), category_name(*store, y.category));
                case COL_ACCOUNT;  c = compare_nocase(account_name(*store, x.account), account_name(*store, y.account));
                case COL_STATUS;   c = cast(int) y.status - cast(int) x.status;
                case COL_AMOUNT;   c = ifx x.amount < y.amount then -1 else ifx x.amount > y.amount then 1 else 0;
            }
            if c != 0 return c;
            return a - b;   // Ties: newest first.
        });
        if st.table.sort_desc {
            n := indices.count;
            for 0..n / 2 - 1 { indices[it], indices[n - 1 - it] = indices[n - 1 - it], indices[it]; }
        }
    } else if !st.table.sort_desc {
        n := indices.count;
        for 0..n / 2 - 1 { indices[it], indices[n - 1 - it] = indices[n - 1 - it], indices[it]; }
    }

    st.rows.count = 0;
    if grouped {
        header_index := -1;
        for indices {
            txn := *store.transactions[it];
            if header_index < 0 || st.rows[header_index].day != txn.day {
                h := array_add(*st.rows);
                h.header = true;
                h.day = txn.day;
                header_index = st.rows.count - 1;
            }
            h := *st.rows[header_index];
            h.count += 1;
            if counts_for(txn, account) {
                if txn.amount > 0 h.money_in += txn.amount; else h.money_out -= txn.amount;
            }
            array_add(*st.rows, .{txn = it, day = txn.day});
        }
    } else {
        for indices array_add(*st.rows, .{txn = it, day = store.transactions[it].day});
    }

    // Keep the chosen transactions that are still listed.
    if st.picked.count {
        chosen := NewArray(store.transactions.count, bool,, temp);
        for st.picked {
            index := store_find_transaction(*store, it);
            if index >= 0 chosen[index] = true;
            free(it);
        }
        st.picked.count = 0;
        for * st.rows if !it.header && chosen[it.txn] {
            it.picked = true;
            array_add(*st.picked, copy_string(store.transactions[it.txn].id));
        }
        if !st.picked.count set_string(*st.selected_id, "");
        else if st.picked.count == 1 {
            set_string(*st.selected_id, st.picked[0]);
            clear_picked(st);
        }
    }

    // Keep the selection on the same transaction.
    st.table.selected = -1;
    if st.selected_id.count {
        for st.rows if !it.header && store.transactions[it.txn].id == st.selected_id { st.table.selected = it_index; break; }
        if st.table.selected >= 0 && !st.picked.count {
            row_h := px(theme.row_height);
            ui_scroll_to(*st.table.scroll, st.table.selected * row_h, row_h, max(st.table.scroll.view, row_h * 4));
        }
    }
}

hash_key_string :: (s: string) -> u64 {
    h: u64 = 0xcbf29ce484222325;
    for 0..s.count - 1 { h ^= s[it]; h *= 0x100000001b3; }
    return h;
}

custom_period_label :: (p: Period) -> string {
    if p.first == p.last return format_date(p.first);
    a := civil_from_days(p.first);
    b := civil_from_days(p.last);
    if a.day == 1 && civil_from_days(p.last + 1).day == 1 || (a.day == 1 && p.last == app.today) {
        if a.year == b.year && a.month == b.month return tprint("% %", MONTH_LONG[a.month - 1], a.year);
        return tprint("% – %", format_month(month_key(a.year, a.month)), format_month(month_key(b.year, b.month)));
    }
    return tprint("% – %", format_date_column(p.first), format_date(p.last));
}
