// Accounts: how is each balance moving? A table of accounts, the selected
// one's balance over time, and its month-by-month ledger.

Accounts_State :: struct {
    selected: int = -1;
    range:    int = 1;
    table:        Table_State;
    months_table: Table_State;
    months_key:   u64;
    months:       [..] Account_Month;
}

Account_Month :: struct {
    month:     s32;
    money_in:  s64;
    money_out: s64;
    count:     int;
    closing:   s64;
}

RANGE_LABELS :: string.["30 days", "90 days", "1 year", "All"];

range_period :: (range: int) -> Period {
    days: s64 = 30;
    if range == 1 days = 90;
    if range == 2 days = 365;
    if range == 3 days = max(app.today - analytics.first_day + 1, 30);
    return .{app.today - days + 1, app.today};
}

draw_accounts_page :: (r_in: Rect) {
    st := *app.accounts;
    r := r_in;
    order := account_order();
    if st.selected < 0 && order.count st.selected = order[0];

    bar := toolbar_rect(*r);
    ui_segmented("range##accounts", cut_left(*bar, ui_segmented_width(RANGE_LABELS)), RANGE_LABELS, *st.range);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), bar, "Balance history is reconstructed from transactions, working back from today's balances.", theme.text_muted, .RIGHT);

    period := range_period(st.range);
    flow := period_flow(period);
    total, total_before, spending, savers: s64;
    saver_count, spending_count := 0, 0;
    for store.accounts {
        total += it.balance;
        total_before += balance_at(it_index, period.first - 1);
        if it.type == .TRANSACTIONAL { spending += it.balance; spending_count += 1; }
        if it.type == .SAVER { savers += it.balance; saver_count += 1; }
    }
    change := total - total_before;
    no_data := !store.accounts.count;
    range_name := to_lower_temp(RANGE_LABELS[st.range]);
    if st.range == 3 range_name = "all history";

    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));
    cut_top(*r, px(8));
    metrics := Metric.[
        .{label = "Total balance", value = format_money(total), detail = format_count(store.accounts.count, "account", "accounts"), loading = no_data},
        .{label = "Change", value = format_money(change, .ALWAYS), value_color = ifx change > 0 then theme.positive else 0, detail = tprint("over %", range_name), loading = no_data},
        .{label = "Money in", value = format_money(flow.money_in), value_color = ifx flow.money_in then theme.positive else 0, detail = tprint("over %", range_name), loading = no_data},
        .{label = "Money out", value = format_money(flow.money_out), detail = tprint("over %", range_name), loading = no_data, roll_up = false},
        .{label = "Spending accounts", value = format_money(spending), detail = format_count(spending_count, "account", "accounts"), loading = no_data},
        .{label = "Savers", value = format_money(savers), detail = format_count(saver_count, "saver", "savers"), loading = no_data},
    ];
    draw_metric_strip(appear_begin(strip, 0), metrics, "accounts-metrics");
    appear_end();

    // Left: the accounts (as tall as they need) and the selected one's
    // ledger. Right: its balance, and its money in and out by month.
    left := cut_left(*r, r.w * 0.46);
    cut_left(*r, px(8));
    rows := max(order.count, 3) + 1;   // +1: the totals row.
    table_h := px(theme.panel_header_height + 26 + 2) + rows * px(36);
    if left.h - table_h < px(160) table_h = left.h * 0.5;
    draw_account_table(appear_begin(cut_top(*left, table_h), 1), st, order, period);
    appear_end();
    cut_top(*left, px(8));
    update_months(st);
    draw_account_months(appear_begin(left, 2), st);
    appear_end();

    chart_r := cut_top(*r, r.h * 0.56);
    cut_top(*r, px(8));
    draw_account_chart(appear_begin(chart_r, 3), st);
    appear_end();
    draw_account_flow(appear_begin(r, 4), st);
    appear_end();
}

#scope_file

ACCOUNT_TABLE_COLUMNS :: Column.[
    .{"Account",  0,   .LEFT,  false, 0},
    .{"Type",     92,  .LEFT,  false, 660},
    .{"Change",   96,  .RIGHT, false, 0},
    .{"In",       92,  .RIGHT, false, 560},
    .{"Out",      92,  .RIGHT, false, 560},
    .{"Balance",  110, .RIGHT, false, 0},
];

draw_account_table :: (r: Rect, st: *Accounts_State, order: [] s32, period: Period) {
    content, _ := panel_begin(r, "Accounts", tprint("% · select one for its history", to_lower_temp(RANGE_LABELS[st.range])));
    tbl: Data_Table;
    selected_row := -1;
    for order if it == st.selected selected_row = it_index;
    st.table.selected = selected_row;
    body := content;
    totals_r := cut_bottom(*body, px(34));
    table_begin(*tbl, "accounts-table", body, ACCOUNT_TABLE_COLUMNS, *st.table, order.count, keyboard = true, row_height = px(36));
    if !order.count {
        table_end(*tbl);
        table_skeleton(*tbl, 6);
        return;
    }
    for i: tbl.first..tbl.last {
        acct := order[i];
        a := *store.accounts[acct];
        row := table_row(*tbl, i);
        name := table_cell(*tbl, row, 0);
        draw_text_fit(fonts.regular, px(theme.font_size_body), rect(name.x, name.y + px(3), name.w, px(18)), a.name, theme.text);
        owner := ifx a.ownership == .JOINT then "Joint" else "Individual";
        draw_text_fit(fonts.regular, px(theme.font_size_small), rect(name.x, name.y + px(19), name.w, px(14)), tprint("% · since %", owner, format_date(ts_day(a.created))), theme.text_muted);
        if table_column_shown(*tbl, 1) draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), account_type_label(a), theme.text_secondary);
        change := a.balance - balance_at(acct, period.first - 1);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 2), ifx change then format_money(change, .ALWAYS) else "—",
                          ifx change > 0 then theme.positive else ifx change < 0 then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, 3) {
            f := period_flow(period, acct);
            draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 3), ifx f.money_in then format_money(f.money_in) else "—", ifx f.money_in then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
            draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 4), ifx f.money_out then format_money(f.money_out) else "—", ifx f.money_out then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
        }
        draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 5), format_money(a.balance), theme.text, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if st.table.selected >= 0 && st.table.selected < order.count st.selected = order[st.table.selected];

    // Totals.
    draw_rect(snap(rect(totals_r.x + hairline(), totals_r.y, totals_r.w - 2 * hairline(), totals_r.h - hairline())), theme.panel_header);
    ui_divider(totals_r.x, totals_r.y, totals_r.w, theme.border);
    row := rect(totals_r.x, totals_r.y, totals_r.w - px(10), totals_r.h);
    total, before: s64;
    for store.accounts { total += it.balance; before += balance_at(it_index, period.first - 1); }
    f := period_flow(period);
    draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 0), tprint("Total · % accounts", store.accounts.count), theme.text_secondary);
    change := total - before;
    draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 2), format_money(change, .ALWAYS), ifx change > 0 then theme.positive else theme.text_secondary, .RIGHT, .{tabular = true});
    if table_column_shown(*tbl, 3) {
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 3), format_money(f.money_in), theme.text_secondary, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 4), format_money(f.money_out), theme.text_secondary, .RIGHT, .{tabular = true});
    }
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 5), format_money(total), theme.text, .RIGHT, .{tabular = true});
}

update_months :: (st: *Accounts_State) {
    if st.selected < 0 || st.selected >= store.accounts.count return;
    key := hash_key(store.version, cast(u64) st.selected, cast(u64) app.today, cast(u64) settings.exclude_transfers);
    if key == st.months_key return;
    st.months_key = key;
    st.months.count = 0;
    last_month := month_key_from_day(app.today);
    first_month := month_key_from_day(analytics.first_day);
    for < m: first_month..last_month {
        row := array_add(*st.months);
        row.month = m;
        p := month_period(m);
        f := period_flow(p, st.selected);
        row.money_in = f.money_in;
        row.money_out = f.money_out;
        row.count = f.count;
        row.closing = balance_at(st.selected, min(p.last, app.today));
    }
}

draw_account_flow :: (r: Rect, st: *Accounts_State) {
    name := ifx st.selected >= 0 && st.selected < store.accounts.count then store.accounts[st.selected].name else "";
    content, _ := panel_begin(r, "In and out by month", tprint("% · last 12 months", name));
    chart := rect_inset_xy(content, px(12), px(8));
    if !st.months.count { draw_empty_state(chart, "Loading…", "", .SYNC); return; }
    n := min(st.months.count, 12);
    buckets := NewArray(n, Flow_Bucket,, temp);
    for i: 0..n - 1 {
        m := st.months[n - 1 - i];
        p := month_period(m.month);
        buckets[i] = .{p.first, min(p.last, app.today), m.money_in, m.money_out, m.count};
    }
    draw_flow_chart(tprint("account-flow-%", st.selected), chart, buckets, app.today, monthly = true);
}

draw_account_chart :: (r: Rect, st: *Accounts_State) {
    if st.selected < 0 || st.selected >= store.accounts.count {
        content, _ := panel_begin(r, "Balance");
        draw_empty_state(content, "No account selected");
        return;
    }
    a := *store.accounts[st.selected];
    period := range_period(st.range);
    start_balance := balance_at(st.selected, period.first);
    content, header := panel_begin(r, tprint("% balance", a.name), tprint("% → %", format_money(start_balance), format_money(a.balance)));
    chart := rect_inset_xy(content, px(12), px(10));
    if !store.transactions.count {
        draw_empty_state(chart, "Loading history…", "", .SYNC);
        return;
    }
    an := *analytics;
    first := max(period.first, an.first_day);
    n := app.today - first + 1;
    start := st.selected * an.day_count + (first - an.first_day);
    series := array_view(an.balance_hist, start, n);
    draw_balance_chart(tprint("balance-%", st.range), chart, series, first, app.today, theme.chart_line);
    if sync.phase == .LOADING draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(chart.x, chart.y, chart.w, px(14)), "History still loading: earlier balances may change.", theme.held, .RIGHT);
}

MONTH_COLUMNS :: Column.[
    .{"Month",   0,   .LEFT,  false, 0},
    .{"Txns",    56,  .RIGHT, false, 0},
    .{"In",      100, .RIGHT, false, 0},
    .{"Out",     100, .RIGHT, false, 0},
    .{"Net",     100, .RIGHT, false, 0},
    .{"Closing", 112, .RIGHT, false, 0},
];

draw_account_months :: (r: Rect, st: *Accounts_State) {
    name := ifx st.selected >= 0 && st.selected < store.accounts.count then store.accounts[st.selected].name else "";
    content, _ := panel_begin(r, tprint("% by month", name), ifx settings.exclude_transfers then "excl. transfers between your accounts · double-click a month" else "double-click a month");
    if st.selected < 0 || st.selected >= store.accounts.count return;
    tbl: Data_Table;
    table_begin(*tbl, "account-months", content, MONTH_COLUMNS, *st.months_table, st.months.count);
    for i: tbl.first..tbl.last {
        m := st.months[i];
        row := table_row(*tbl, i);
        label := tprint("% %", MONTH_LONG[month_key_month(m.month) - 1], month_key_year(m.month));
        if m.month == month_key_from_day(app.today) label = tprint("% (so far)", label);
        draw_text_fit(fonts.regular, px(theme.font_size_body), table_cell(*tbl, row, 0), label, theme.text);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), format_grouped(m.count), theme.text_muted, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 2), ifx m.money_in then format_money(m.money_in) else "—", ifx m.money_in then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 3), ifx m.money_out then format_money(m.money_out) else "—", ifx m.money_out then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
        net := m.money_in - m.money_out;
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 4), ifx net then format_money(net, .ALWAYS) else "—", ifx net > 0 then theme.positive else ifx net < 0 then theme.text else theme.text_faint, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 5), format_money(m.closing), theme.text, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if tbl.activated >= 0 show_transactions(account = st.selected, custom = month_period(st.months[tbl.activated].month));
}
