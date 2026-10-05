// Spending: where does the money go, and how does it compare with before?

Spending_State :: struct {
    mode:    int;          // 0: one month, 1: three months, 2: twelve months.
    month:   s32;          // The (last) month shown.
    account: int;
    expanded: [4] bool = .[true, true, true, true];
    categories_table: Table_State;
    merchants_table:  Table_State;
    rows: [..] Spend_Row;
    initialized: bool;
}

Spend_Row_Kind :: enum u8 { PARENT; CHILD; BUCKET; }

Spend_Row :: struct {
    kind: Spend_Row_Kind;
    data: Category_Spend;
    slot: int;   // Parent slot (0..3) for parents and their children.
}

SPEND_MODES :: string.["Month", "3 months", "12 months"];

spending_period :: (st: *Spending_State) -> Period {
    months := ifx st.mode == 0 then 1 else ifx st.mode == 1 then 3 else 12;
    first := first_day_of_month(st.month - months + 1);
    last := min(month_period(st.month).last, app.today);
    return .{first, last};
}

draw_spending_page :: (r_in: Rect) {
    st := *app.spending;
    current := month_key_from_day(app.today);
    if !st.initialized { st.initialized = true; st.month = current; }
    st.month = min(st.month, current);
    r := r_in;

    // Toolbar: month stepper, span, account.
    bar := toolbar_rect(*r);
    prev_r := cut_left(*bar, px(28));
    if ui_icon_button("prev-month", .CHEVRON_LEFT, prev_r, "Previous month") st.month -= 1;
    label_r := cut_left(*bar, px(150));
    month_label := tprint("% %", MONTH_LONG[month_key_month(st.month) - 1], month_key_year(st.month));
    if st.mode > 0 {
        months := ifx st.mode == 1 then 3 else 12;
        first := st.month - months + 1;
        month_label = tprint("% – %", format_month(first), format_month(st.month));
    }
    draw_rolling_text(ui_id("spend-month-label"), fonts.semibold, px(theme.font_size_body), label_r, month_label, theme.text, .CENTER);
    next_r := cut_left(*bar, px(28));
    if ui_icon_button("next-month", .CHEVRON_RIGHT, next_r, "Next month", enabled = st.month < current) st.month += 1;
    cut_left(*bar, px(10));
    ui_segmented("spend-mode", cut_left(*bar, ui_segmented_width(SPEND_MODES)), SPEND_MODES, *st.mode);
    cut_left(*bar, px(8));
    acct_items, acct_map := account_filter_items();
    ui_dropdown("account##spend", cut_left(*bar, px(170)), acct_items, *st.account);
    if st.month != current {
        cut_left(*bar, px(8));
        if ui_button("This month##spend", cut_left(*bar, px(96)), .GHOST) st.month = current;
    }
    account := ifx st.account > 0 && st.account < acct_map.count then acct_map[st.account] else -1;

    period := spending_period(st);
    previous := previous_period(period);
    b := spend_breakdown(period, account);
    flow := period_flow(period, account);
    days := period_days(period);
    partial := period.last == app.today && st.month == current;
    prev_label := period_label(b.previous);
    top_name := "";
    for b.rows if it.category >= 0 { top_name = store.categories[it.category].name; break; }
    uncategorised: Category_Spend;
    for b.rows if it.category == -1 uncategorised = it;

    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));
    cut_top(*r, px(8));
    loading := !store.transactions.count;
    delta := format_change_percent(b.total, b.previous_total);
    metrics := Metric.[
        .{label = "Spent", value = format_money(b.total), detail = ifx partial then tprint("% days so far", days) else tprint("% days", days), loading = loading, roll_up = false},
        .{label = tprint("vs %", prev_label), value = format_money(b.total - b.previous_total, .ALWAYS), delta = delta, delta_up = b.total >= b.previous_total,
          delta_good = ifx b.total > b.previous_total then -1 else 1, detail = tprint("was %", format_money_whole(b.previous_total)), loading = loading,
          tooltip = ifx partial then "This period isn't over yet, so it's compared with the same days before it." else ""},
        .{label = "Money in", value = format_money(flow.money_in), value_color = ifx flow.money_in then theme.positive else 0, detail = ifx settings.exclude_transfers then "excl. own transfers" else "", loading = loading},
        .{label = "Net", value = format_money(flow.money_in - flow.money_out, .ALWAYS), value_color = ifx flow.money_in > flow.money_out then theme.positive else 0, detail = "in minus out", loading = loading},
        .{label = "Per day", value = format_money(b.total / max(days, 1)), detail = "average spend", loading = loading},
        .{label = "Uncategorised", value = format_money(uncategorised.spent), detail = format_count(uncategorised.count, "purchase", "purchases"), loading = loading,
          value_color = ifx uncategorised.count then theme.text_secondary else 0},
        .{label = "Biggest category", value = ifx top_name.count then top_name else "—", detail = ifx b.rows.count && b.rows[0].category >= 0 then format_money(b.rows[0].spent) else "", loading = loading},
    ];
    draw_metric_strip(appear_begin(strip, 0), metrics, "spend-metrics");
    appear_end();

    left := cut_left(*r, r.w * 0.47);
    cut_left(*r, px(8));
    draw_category_table(appear_begin(left, 1), st, b, period);
    appear_end();
    chart_r := cut_top(*r, r.h * 0.5);
    cut_top(*r, px(8));
    draw_month_chart(appear_begin(chart_r, 2), st, account);
    appear_end();
    draw_merchants(appear_begin(r, 3), st, period, account);
    appear_end();
}

#scope_file

CATEGORY_COLUMNS :: Column.[
    .{"Category", 0,   .LEFT,  false, 0},
    .{"Txns",     50,  .RIGHT, false, 560},
    .{"Share",    90,  .LEFT,  false, 600},
    .{"Spent",    100, .RIGHT, false, 0},
    .{"Before",   92,  .RIGHT, false, 520},
    .{"Change",   70,  .RIGHT, false, 0},
];

draw_category_table :: (r: Rect, st: *Spending_State, b: *Spend_Breakdown, period: Period) {
    content, header := panel_begin(r, "By category", controls = 90, meta = tprint("% · before: %", format_money(b.total), period_label(b.previous)));
    all_open := st.expanded[0] && st.expanded[1] && st.expanded[2] && st.expanded[3];
    toggle_r := cut_right(*header, px(84));
    if ui_button(ifx all_open then "Collapse##cat" else "Expand##cat", toggle_r, .GHOST, ifx all_open then Icon.CHEVRON_UP else .CHEVRON_DOWN) {
        for * st.expanded it.* = !all_open;
    }

    // Rows: each parent, its children when expanded, then the buckets.
    st.rows.count = 0;
    for parent, slot: b.parents {
        if parent.spent == 0 && parent.previous == 0 continue;
        s := parent_slot(parent.category);
        array_add(*st.rows, .{kind = .PARENT, data = parent, slot = s});
        if s >= 0 && st.expanded[s] {
            for b.rows if it.parent == parent.category && it.category >= 0 array_add(*st.rows, .{kind = .CHILD, data = it, slot = s});
        }
    }
    for b.rows if it.category < 0 array_add(*st.rows, .{kind = .BUCKET, data = it, slot = -1});

    tbl: Data_Table;
    table_begin(*tbl, "spend-categories", content, CATEGORY_COLUMNS, *st.categories_table, st.rows.count, keyboard = true);
    if !store.transactions.count {
        table_end(*tbl);
        table_skeleton(*tbl, 10);
        return;
    }
    if !st.rows.count {
        table_end(*tbl);
        draw_empty_state(content, "No spending in this period");
        return;
    }
    total := max(b.total, 1);
    for i: tbl.first..tbl.last {
        row_data := *st.rows[i];
        d := row_data.data;
        row := table_row(*tbl, i);
        name_r := table_cell(*tbl, row, 0);
        is_parent := row_data.kind == .PARENT;
        color: Color;
        name: string;
        if row_data.kind == .BUCKET {
            color = UNCATEGORISED_COLOR;
            name = ifx d.category == -1 then "Uncategorised" else "Other payments";
        } else {
            color = parent_color(d.parent);
            name = store.categories[d.category].name;
        }
        if is_parent {
            draw_rect(snap(rect(row.x, row.y, tbl.body.w, row.h)), color_with_alpha(theme.panel_header, 0.7));
            open := row_data.slot >= 0 && st.expanded[row_data.slot];
            draw_icon(ifx open then Icon.CHEVRON_DOWN else .CHEVRON_RIGHT, name_r.x + px(5), name_r.y + name_r.h * 0.5, px(8), theme.text_muted);
            draw_rect(snap(rect(name_r.x + px(16), name_r.y + (name_r.h - px(10)) * 0.5, px(10), px(10))), color, px(2));
            draw_text_fit(fonts.semibold, px(theme.font_size_body), rect(name_r.x + px(32), name_r.y, name_r.w - px(32), name_r.h), name, theme.text);
        } else if row_data.kind == .CHILD {
            draw_rect(snap(rect(name_r.x + px(34), name_r.y + (name_r.h - px(8)) * 0.5, px(8), px(8))), color, px(2));
            draw_text_fit(fonts.regular, px(theme.font_size_body), rect(name_r.x + px(48), name_r.y, name_r.w - px(48), name_r.h), name, theme.text_secondary);
        } else {
            draw_rect_outline(snap(rect(name_r.x + px(16), name_r.y + (name_r.h - px(10)) * 0.5, px(10), px(10))), 0, theme.text_faint, hairline(), px(2));
            draw_text_fit(fonts.regular, px(theme.font_size_body), rect(name_r.x + px(32), name_r.y, name_r.w - px(32), name_r.h), name, theme.text_secondary);
        }
        font := ifx is_parent then fonts.semibold else fonts.regular;
        if table_column_shown(*tbl, 1) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), format_grouped(d.count), theme.text_muted, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 2) {
            share := cast(float) d.spent / cast(float) total;
            cell := table_cell(*tbl, row, 2);
            draw_share_bar(rect(cell.x, cell.y, cell.w - px(34), cell.h), share * appear(1 + i / 4), color);
            draw_text_in_rect(fonts.regular, px(theme.font_size_small), cell, format_percent(share, 0), theme.text_muted, .RIGHT, .{tabular = true});
        }
        draw_text_in_rect(font, px(theme.font_size_body), table_cell(*tbl, row, 3), format_money(d.spent), ifx d.spent < 0 then theme.positive else theme.text, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 4) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 4), ifx d.previous then format_money(d.previous) else "—", theme.text_muted, .RIGHT, .{tabular = true});
        change := format_change_percent(d.spent, d.previous);
        if !change.count change = ifx d.spent > 0 then "new" else "—";
        up := d.spent > d.previous;
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 5), change, ifx d.previous && up then theme.held else theme.text_secondary, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);

    if tbl.clicked >= 0 && st.rows[tbl.clicked].kind == .PARENT {
        s := st.rows[tbl.clicked].slot;
        if s >= 0 st.expanded[s] = !st.expanded[s];
    }
    if tbl.activated >= 0 {
        d := st.rows[tbl.activated].data;
        if d.category != -2 show_transactions(category = d.category, custom = period);
    }
}

draw_month_chart :: (r: Rect, st: *Spending_State, account: int) {
    content, _ := panel_begin(r, "Monthly spending", "last 12 months by parent category · click a month to open it");
    chart := rect_inset_xy(content, px(12), px(8));
    if !store.transactions.count { draw_empty_state(chart, "Loading…", "", .SYNC); return; }
    current := month_key_from_day(app.today);
    months: [12] Month_Stack;
    names: [4] string;
    for pid, k: PARENT_CATEGORY_IDS {
        p := store_find_category(*store, pid);
        names[k] = ifx p >= 0 then store.categories[p].name else pid;
    }
    for i: 0..11 {
        m := current - 11 + i;
        months[i].month = cast(s32) m;
        bd := spend_breakdown(month_period(m), account);
        for bd.parents {
            k := parent_slot(it.category);
            if k >= 0 months[i].segments[k] = it.spent;
        }
        for bd.rows if it.category < 0 months[i].segments[4] += it.spent;
    }
    clicked := draw_month_stack("spend-months", chart, months, ifx st.mode == 0 then st.month else -1, names);
    if clicked >= 0 { st.month = clicked; st.mode = 0; }
}

MERCHANT_COLUMNS :: Column.[
    .{"Merchant", 0,   .LEFT,  false, 0},
    .{"Category", 150, .LEFT,  false, 640},
    .{"Txns",     50,  .RIGHT, false, 0},
    .{"Average",  86,  .RIGHT, false, 560},
    .{"Spent",    98,  .RIGHT, false, 0},
    .{"Last",     66,  .RIGHT, false, 480},
];

draw_merchants :: (r: Rect, st: *Spending_State, period: Period, account: int) {
    list := merchants(period, account);
    content, _ := panel_begin(r, "Top merchants", tprint("% merchants · double-click for their transactions", format_grouped(list.rows.count)));
    tbl: Data_Table;
    table_begin(*tbl, "spend-merchants", content, MERCHANT_COLUMNS, *st.merchants_table, list.rows.count);
    if !list.rows.count {
        table_end(*tbl);
        if store.transactions.count draw_empty_state(content, "No purchases in this period");
        else table_skeleton(*tbl, 6);
        return;
    }
    for i: tbl.first..tbl.last {
        m := *list.rows[i];
        row := table_row(*tbl, i);
        draw_text_fit(fonts.regular, px(theme.font_size_body), table_cell(*tbl, row, 0), m.name, theme.text);
        if table_column_shown(*tbl, 1) draw_category(table_cell(*tbl, row, 1), m.category, true);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 2), format_grouped(m.count), theme.text_muted, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 3) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 3), format_money(m.spent / max(m.count, 1)), theme.text_secondary, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 4), format_money(m.spent), theme.text, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 5) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 5), format_date_short(m.last_day, app.today), theme.text_muted, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if tbl.activated >= 0 show_transactions(search = list.rows[tbl.activated].name, custom = period);
}
