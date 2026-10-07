// Tags: what did each tagged trip, project or habit cost?

Tags_State :: struct {
    search:   Text_Buffer;
    table:    Table_State;
    selected: s32 = -1;
    rows:     [..] s32;
    rows_key: u64;
    txn_table: Table_State;
    txns:     [..] s32;
    txns_key: u64;
}

draw_tags_page :: (r_in: Rect) {
    st := *app.tags;
    r := r_in;
    bar := toolbar_rect(*r);
    ui_text_input("search##tags", cut_left(*bar, px(260)), *st.search, "Filter tags…", .SEARCH);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), bar, tprint("% · Up allows 6 tags per transaction", format_count(store.tags.count, "tag", "tags")), theme.text_muted, .RIGHT);

    // Rows: tags matching the filter, sorted by the chosen column.
    needle := to_lower_temp(trim(buffer_string(*st.search)));
    key := hash_key(store.version, cast(u64) (st.table.sort_column + 3), cast(u64) st.table.sort_desc, hash_string(needle));
    if key != st.rows_key {
        st.rows_key = key;
        st.rows.count = 0;
        for tag, i: store.tags if text_contains(tag.label, needle) array_add(*st.rows, cast(s32) i);
        tag_sort_column = st.table.sort_column;
        quick_sort(st.rows, (a: s32, b: s32) -> int {
            x := ifx a < analytics.tags.count then analytics.tags[a] else Tag_Stat.{};
            y := ifx b < analytics.tags.count then analytics.tags[b] else Tag_Stat.{};
            c := 0;
            if tag_sort_column == {
                case 0; c = compare_strings(store.tags[a].label, store.tags[b].label);
                case 1; c = x.count - y.count;
                case 2; c = cast(int) sign(x.money_out - y.money_out);
                case 3; c = cast(int) sign(x.money_in - y.money_in);
                case;   c = cast(int) sign(x.last_day - y.last_day);
            }
            return ifx c != 0 then c else a - b;
        });
        if st.table.sort_desc {
            n := st.rows.count;
            for 0..n / 2 - 1 { st.rows[it], st.rows[n - 1 - it] = st.rows[n - 1 - it], st.rows[it]; }
        }
    }
    if st.selected < 0 && st.rows.count st.selected = st.rows[0];

    left := cut_left(*r, r.w * 0.42);
    cut_left(*r, px(8));
    rows := max(st.rows.count, 6);
    table_h := px(theme.panel_header_height + 26 + 2) + rows * px(theme.row_height);
    if left.h - table_h < px(200) table_h = left.h;
    draw_tag_table(appear_begin(cut_top(*left, table_h), 0), st);
    appear_end();
    if left.h > px(200) {
        cut_top(*left, px(8));
        draw_tag_months(appear_begin(left, 2), st);
        appear_end();
    }
    draw_tag_detail(appear_begin(r, 1), st);
    appear_end();
}

#scope_file

tag_sort_column: int;

sign :: (v: s64) -> s64 { return ifx v > 0 then 1 else ifx v < 0 then -1 else 0; }

hash_string :: (s: string) -> u64 {
    h: u64 = 0xcbf29ce484222325;
    for 0..s.count - 1 { h ^= s[it]; h *= 0x100000001b3; }
    return h;
}

TAG_COLUMNS :: Column.[
    .{"Tag",      0,   .LEFT,  true, 0},
    .{"Txns",     58,  .RIGHT, true, 0},
    .{"Spent",    100, .RIGHT, true, 0},
    .{"Received", 96,  .RIGHT, true, 560},
    .{"Last used",84,  .RIGHT, true, 480},
];

draw_tag_table :: (r: Rect, st: *Tags_State) {
    content, _ := panel_begin(r, "Tags", "across all loaded history");
    if st.table.sort_column < 0 { st.table.sort_column = 4; st.table.sort_desc = true; }
    selected_row := -1;
    for st.rows if it == st.selected selected_row = it_index;
    st.table.selected = selected_row;
    tbl: Data_Table;
    table_begin(*tbl, "tags-table", content, TAG_COLUMNS, *st.table, st.rows.count, keyboard = true);
    if tbl.sort_changed st.rows_key = 0;
    if !st.rows.count {
        table_end(*tbl);
        if sync.phase == .LOADING && !store.tags.count table_skeleton(*tbl, 6);
        else draw_empty_state(content, ifx store.tags.count then "No tags match" else "No tags yet", "Tag transactions in the Transactions inspector.", .TAG);
        return;
    }
    for i: tbl.first..tbl.last {
        tag := st.rows[i];
        ts := ifx tag < analytics.tags.count then analytics.tags[tag] else Tag_Stat.{};
        row := table_row(*tbl, i);
        name := table_cell(*tbl, row, 0);
        draw_icon(.TAG, name.x + px(5), name.y + name.h * 0.5, px(10), theme.text_muted);
        draw_text_fit(fonts.regular, px(theme.font_size_body), rect(name.x + px(18), name.y, name.w - px(18), name.h), store.tags[tag].label, theme.text);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), format_grouped(ts.count), theme.text_muted, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 2), ifx ts.money_out then format_money(ts.money_out) else "—", ifx ts.money_out then theme.text else theme.text_faint, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 3) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 3), ifx ts.money_in then format_money(ts.money_in) else "—", ifx ts.money_in then theme.positive else theme.text_faint, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 4) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 4), ifx ts.count then format_date_short(ts.last_day, app.today) else "—", theme.text_muted, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if st.table.selected >= 0 && st.table.selected < st.rows.count st.selected = st.rows[st.table.selected];
}

// Money in and out with the tag, month by month over its span.
draw_tag_months :: (r: Rect, st: *Tags_State) {
    if st.selected < 0 || st.selected >= store.tags.count {
        content, _ := panel_begin(r, "By month");
        draw_empty_state(content, "Select a tag", "", .TAG);
        return;
    }
    tag := st.selected;
    ts := ifx tag < analytics.tags.count then analytics.tags[tag] else Tag_Stat.{};
    content, _ := panel_begin(r, "By month", tprint("\"%\"", store.tags[tag].label));
    chart := rect_inset_xy(content, px(12), px(8));
    if !ts.count { draw_empty_state(chart, "Not used yet", "", .TAG); return; }
    last := month_key_from_day(ts.last_day);
    first := min(month_key_from_day(ts.first_day), last - 5);
    first = max(first, last - 23);
    n := last - first + 1;
    buckets := NewArray(n, Flow_Bucket,, temp);
    for i: 0..n - 1 {
        p := month_period(first + i);
        buckets[i].first_day = p.first;
        buckets[i].last_day = min(p.last, app.today);
    }
    for * t: store.transactions {
        if !txn_has_tag(t, tag) continue;
        i := t.month - first;
        if i < 0 || i >= n continue;
        if t.amount > 0 buckets[i].money_in += t.amount; else buckets[i].money_out -= t.amount;
        buckets[i].count += 1;
    }
    draw_flow_chart(tprint("tag-months-%", tag), chart, buckets, app.today, monthly = true);
}

TAG_TXN_COLUMNS :: Column.[
    .{"Date",        78,  .LEFT,  false, 0},
    .{"Description", 0,   .LEFT,  false, 0},
    .{"Category",    170, .LEFT,  false, 620},
    .{"Amount",      108, .RIGHT, false, 0},
];

draw_tag_detail :: (r_in: Rect, st: *Tags_State) {
    r := r_in;
    if st.selected < 0 || st.selected >= store.tags.count {
        content, _ := panel_begin(r, "Tag");
        draw_empty_state(content, "Select a tag", "", .TAG);
        return;
    }
    tag := st.selected;
    label := store.tags[tag].label;
    ts := ifx tag < analytics.tags.count then analytics.tags[tag] else Tag_Stat.{};

    key := hash_key(store.version, cast(u64) tag);
    if key != st.txns_key {
        st.txns_key = key;
        st.txns.count = 0;
        for * t, i: store.transactions if txn_has_tag(t, tag) array_add(*st.txns, cast(s32) i);
        st.txn_table.selected = -1;
    }

    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));
    cut_top(*r, px(8));
    span := ifx ts.count then tprint("% – %", format_date(ts.first_day), format_date(ts.last_day)) else "";
    days := ifx ts.count then ts.last_day - ts.first_day + 1 else 0;
    metrics := Metric.[
        .{label = label, value = format_money(ts.money_out), detail = "spent"},
        .{label = "Received", value = format_money(ts.money_in), value_color = ifx ts.money_in then theme.positive else 0, detail = "refunds and payments in"},
        .{label = "Transactions", value = format_grouped(ts.count), detail = ifx ts.count then tprint("average %", format_money((ts.money_out) / max(ts.count, 1))) else ""},
        .{label = "Span", value = ifx days then format_count(days, "day", "days") else "—", detail = span},
    ];
    draw_metric_strip(strip, metrics, "tag-metrics");

    // Where the tagged money went, by category.
    cats_r := cut_top(*r, px(150));
    cut_top(*r, px(8));
    content, _ := panel_begin(cats_r, "By category", tprint("for \"%\"", label));
    inner := rect_inset_xy(content, px(12), px(8));
    totals := NewArray(store.categories.count + 1, s64,, temp);
    for st.txns {
        t := *store.transactions[it];
        if t.amount >= 0 continue;
        totals[ifx t.category >= 0 then t.category else store.categories.count] -= t.amount;
    }
    order: [..] s32;
    order.allocator = temp;
    for totals if it > 0 array_add(*order, cast(s32) it_index);
    // Largest first (insertion sort: a few dozen at most).
    for i: 1..order.count - 1 {
        j := i;
        while j > 0 && totals[order[j - 1]] < totals[order[j]] { order[j - 1], order[j] = order[j], order[j - 1]; j -= 1; }
    }
    biggest := ifx order.count then totals[order[0]] else 1;
    col_w := (inner.w - px(16)) / 2;
    rows_per_col := max(cast(int) (inner.h / px(26)), 1);
    for k: 0..min(order.count, rows_per_col * 2) - 1 {
        c := order[k];
        col := k / rows_per_col;
        rr := rect(inner.x + col * (col_w + px(16)), inner.y + (k % rows_per_col) * px(26), col_w, px(26));
        name := ifx c < store.categories.count then store.categories[c].name else "Uncategorised";
        color := ifx c < store.categories.count then category_color(c) else theme.uncategorised;
        top := rect(rr.x, rr.y, rr.w, px(16));
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(top.x, top.y, top.w - px(80), top.h), name, theme.text_secondary);
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), top, format_money(totals[c]), theme.text, .RIGHT, .{tabular = true});
        draw_share_bar(rect(rr.x, rr.y + px(16), rr.w, px(8)), cast(float) totals[c] / cast(float) biggest * appear(2), color);
    }
    if !order.count draw_empty_state(inner, "No spending with this tag");

    content2, header := panel_begin(r, "Transactions", format_count(st.txns.count, "transaction", "transactions"), controls = 134);
    if ui_link("Open in Transactions##tags", rect(header.x + header.w - px(130), header.y, px(130), header.h)) show_transactions(tag = tag);
    tbl: Data_Table;
    table_begin(*tbl, "tag-txns", content2, TAG_TXN_COLUMNS, *st.txn_table, st.txns.count);
    for i: tbl.first..tbl.last {
        t := *store.transactions[st.txns[i]];
        row := table_row(*tbl, i);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 0), format_date_short(t.day, app.today), theme.text_secondary, .LEFT, .{tabular = true});
        draw_text_fit(fonts.regular, px(theme.font_size_body), table_cell(*tbl, row, 1), t.description, theme.text);
        if table_column_shown(*tbl, 2) draw_category(table_cell(*tbl, row, 2), t.category, t.categorizable);
        draw_amount(table_cell(*tbl, row, 3), t.amount);
    }
    table_end(*tbl);
    if tbl.activated >= 0 show_transactions(tag = tag, select_id = store.transactions[st.txns[tbl.activated]].id);
}
