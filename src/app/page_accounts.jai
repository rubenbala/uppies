// Accounts: how are the balances moving? A table of accounts, and for the
// ones chosen in it, their balance over time and month-by-month ledger.
// Clicking a row chooses that account alone; ticking rows (or Ctrl+click)
// chooses several, and everything beside the table adds them together.

Accounts_State :: struct {
    checked: [..] bool;    // By account index: the chosen accounts. Empty until the accounts arrive.
    cursor:  int = -1;     // Account the keyboard moves from: the one last clicked or ticked.
    was_single := true;    // Exactly one account was chosen last frame.
    range:   int = 1;
    table:        Table_State;
    months_table: Table_State;
    months_key:   u64;
    months:       [..] Account_Month;
    balances:     [..] s64;   // The chosen accounts' end-of-day balance, together, from analytics.first_day.
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

// Shows the Accounts page with just this account chosen.
show_account :: (account: int) {
    choose_only(*app.accounts, account);
    select_page(.ACCOUNTS);
}

draw_accounts_page :: (r_in: Rect) {
    st := *app.accounts;
    r := r_in;
    order := account_order();
    update_checked(st, order);

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

    // Left: the accounts (as tall as they need) and the chosen ones'
    // ledger. Right: their balance, and their money in and out by month.
    left := cut_left(*r, r.w * 0.46);
    cut_left(*r, px(8));
    rows := max(order.count, 3) + 1;   // +1: the totals row.
    table_h := px(theme.panel_header_height + 26 + 2) + rows * px(36);
    if left.h - table_h < px(160) table_h = left.h * 0.5;
    draw_account_table(appear_begin(cut_top(*left, table_h), 1), st, order, period);
    appear_end();
    cut_top(*left, px(8));
    update_history(st);
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

//
// The chosen accounts.
//

choose_only :: (st: *Accounts_State, account: int) {
    array_resize(*st.checked, store.accounts.count);
    for * st.checked it.* = it_index == account;
    st.cursor = account;
}

// The first account is chosen once the accounts arrive; accounts that
// appear later start unticked.
update_checked :: (st: *Accounts_State, order: [] s32) {
    if !order.count { st.checked.count = 0; return; }
    if !st.checked.count choose_only(st, order[0]);
    else if st.checked.count != order.count array_resize(*st.checked, order.count);
}

chosen_count :: (st: *Accounts_State) -> int {
    n := 0;
    for st.checked if it n += 1;
    return n;
}

// The one chosen account, or -1 when there are none or several.
single_chosen :: (st: *Accounts_State) -> int {
    found := -1;
    for st.checked if it {
        if found >= 0 return -1;
        found = it_index;
    }
    return found;
}

is_chosen :: (st: *Accounts_State, account: int) -> bool {
    return account >= 0 && account < st.checked.count && st.checked[account];
}

// What panel titles call the chosen accounts: "Spending", "3 accounts".
chosen_name :: (st: *Accounts_State) -> string {
    single := single_chosen(st);
    if single >= 0 return store.accounts[single].name;
    n := chosen_count(st);
    if n == store.accounts.count return "All accounts";
    return tprint("% accounts", n);
}

chosen_key :: (st: *Accounts_State) -> u64 {
    key: u64 = 0x5E1EC7;
    for st.checked if it key = hash_key(key, cast(u64) it_index);
    return key;
}

chosen_balance_at :: (st: *Accounts_State, day: s64) -> s64 {
    total: s64;
    for st.checked if it total += balance_at(it_index, day);
    return total;
}

// Money in and out over a period, summed over the chosen accounts.
chosen_flow :: (st: *Accounts_State, p: Period) -> Flow_Totals {
    totals: Flow_Totals;
    for st.checked if it {
        f := period_flow(p, it_index);
        totals.money_in  += f.money_in;
        totals.money_out += f.money_out;
        totals.count     += f.count;
    }
    return totals;
}

//
// The accounts table.
//

ACCOUNT_TABLE_COLUMNS :: Column.[
    .{"",         0,   .LEFT,  false, 0},     // "Account": drawn with the tick-all box.
    .{"Type",     92,  .LEFT,  false, 660},
    .{"Change",   96,  .RIGHT, false, 0},
    .{"In",       92,  .RIGHT, false, 560},
    .{"Out",      92,  .RIGHT, false, 560},
    .{"Balance",  110, .RIGHT, false, 0},
];

CHECK_INDENT :: 24.0;   // A tick box and the gap after it.

draw_account_table :: (r: Rect, st: *Accounts_State, order: [] s32, period: Period) {
    content, _ := panel_begin(r, "Accounts", tprint("% · click one, or tick several to add them together", to_lower_temp(RANGE_LABELS[st.range])));
    count := chosen_count(st);
    single := count == 1;
    // One chosen account gets the table's gliding highlight; several are
    // marked where they are.
    if single != st.was_single {
        st.table.sel_alpha = ifx single then 1.0 else 0.0;
        st.was_single = single;
    }
    if single st.cursor = single_chosen(st);
    st.table.selected = -1;
    for order if it == st.cursor st.table.selected = it_index;

    tbl: Data_Table;
    body := content;
    totals_r := cut_bottom(*body, px(34));
    table_begin(*tbl, "accounts-table", body, ACCOUNT_TABLE_COLUMNS, *st.table, order.count, keyboard = true, row_height = px(36), highlight = single);

    // The header sits outside the body's clip.
    pop_clip();
    head := rect(tbl.x[0] + px(CELL_PAD), tbl.header.y, tbl.w[0] - px(2 * CELL_PAD), tbl.header.h);
    title_w := measure_caps("Account");
    if order.count {
        all := count == order.count;
        if ui_checkbox("##accounts-all", rect(head.x, head.y, px(CHECK_INDENT) + title_w, head.h), *all, mixed = count > 0) {
            for * st.checked it.* = all;
        }
    }
    draw_caps(rect(head.x + px(CHECK_INDENT), head.y, head.w - px(CHECK_INDENT), head.h), "Account", theme.text_muted);
    push_clip(tbl.body);

    if !order.count {
        table_end(*tbl);
        table_skeleton(*tbl, 6);
        return;
    }
    toggled := -1;
    for i: tbl.first..tbl.last {
        acct := order[i];
        a := *store.accounts[acct];
        row := table_row(*tbl, i);
        name := table_cell(*tbl, row, 0);

        // The tick box: a click on it (or Ctrl+click anywhere on the row)
        // adds or removes the account; Space does when it has focus.
        cid := ui_id("account-check", acct);
        cw, is_new := ui_widget(cid);
        chosen := st.checked[acct];
        if is_new cw.t = ifx chosen then 1.0 else 0.0;
        ui_animate(*cw.t, ifx chosen then 1.0 else 0.0, 26);
        check_r := rect(row.x, row.y, name.x - row.x + px(CHECK_INDENT), row.h);
        over := tbl.hovered_row == i && rect_contains(check_r, input.mouse_x, input.mouse_y);
        if over ui.cursor = .HAND;
        ui_animate(*cw.hover, ifx over then 1.0 else 0.0, 20);
        ui_focusable(cid);
        ui_update_focus(cw, cid);
        if (tbl.clicked == i && (over || ctrl_down())) || ui_key_activate(cid) toggled = acct;

        if !single && cw.t > 0.01 {
            mark := snap(rect(row.x, row.y, tbl.body.w, row.h - hairline()));
            draw_rect(mark, color_with_alpha(theme.accent_wash, cw.t));
            draw_rect(snap(rect(mark.x, mark.y, px(2), mark.h)), color_with_alpha(theme.accent, cw.t));
        }
        box := snap(rect(name.x, row.y + (row.h - px(CHECKBOX_SIZE)) * 0.5, px(CHECKBOX_SIZE), px(CHECKBOX_SIZE)));
        draw_checkbox(box, cw.t, cw.hover);
        ui_focus_ring(box, cw.focus, px(2));

        text_r := name;
        cut_left(*text_r, px(CHECK_INDENT));
        draw_text_fit(fonts.regular, px(theme.font_size_body), rect(text_r.x, text_r.y + px(3), text_r.w, px(18)), a.name, theme.text);
        owner := ifx a.ownership == .JOINT then "Joint" else "Individual";
        draw_text_fit(fonts.regular, px(theme.font_size_small), rect(text_r.x, text_r.y + px(19), text_r.w, px(14)), tprint("% · since %", owner, format_date(ts_day(a.created))), theme.text_muted);
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
    if toggled >= 0 {
        st.checked[toggled] = !st.checked[toggled];
        st.cursor = toggled;
    } else if tbl.clicked >= 0 {
        choose_only(st, order[tbl.clicked]);
    } else if tbl.selection_changed && st.table.selected >= 0 && st.table.selected < order.count {
        choose_only(st, order[st.table.selected]);   // Moved with the keys.
    }

    // Totals: of the chosen accounts when that is some of them, otherwise of all.
    draw_rect(snap(rect(totals_r.x + hairline(), totals_r.y, totals_r.w - 2 * hairline(), totals_r.h - hairline())), theme.panel_header);
    ui_divider(totals_r.x, totals_r.y, totals_r.w, theme.border);
    row := rect(totals_r.x, totals_r.y, totals_r.w - px(10), totals_r.h);
    count = chosen_count(st);
    some := count >= 2 && count < order.count;
    total, before: s64;
    for store.accounts {
        if some && !st.checked[it_index] continue;
        total += it.balance;
        before += balance_at(it_index, period.first - 1);
    }
    f := ifx some then chosen_flow(st, period) else period_flow(period);
    label := ifx some then tprint("Selected · % of % accounts", count, order.count) else tprint("Total · % accounts", store.accounts.count);
    draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 0), label, ifx some then theme.accent else theme.text_secondary);
    change := total - before;
    draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 2), format_money(change, .ALWAYS), ifx change > 0 then theme.positive else theme.text_secondary, .RIGHT, .{tabular = true});
    if table_column_shown(*tbl, 3) {
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 3), format_money(f.money_in), theme.text_secondary, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), table_cell(*tbl, row, 4), format_money(f.money_out), theme.text_secondary, .RIGHT, .{tabular = true});
    }
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 5), format_money(total), theme.text, .RIGHT, .{tabular = true});
}

//
// The chosen accounts' history.
//

// Their combined daily balance, and their months (newest first) in one pass
// over the transactions.
update_history :: (st: *Accounts_State) {
    key := hash_key(store.version, chosen_key(st), cast(u64) app.today, cast(u64) settings.exclude_transfers);
    if key == st.months_key return;
    st.months_key = key;
    st.months.count = 0;
    st.balances.count = 0;
    an := *analytics;
    if !chosen_count(st) || !an.day_count return;

    array_resize(*st.balances, an.day_count);
    for * st.balances it.* = 0;
    for st.checked if it {
        hist := an.balance_hist.data + it_index * an.day_count;
        for d: 0..an.day_count - 1 st.balances[d] += hist[d];
    }

    last_month := month_key_from_day(app.today);
    first_month := month_key_from_day(an.first_day);
    array_resize(*st.months, last_month - first_month + 1);
    for * st.months {
        it.* = .{};
        it.month = last_month - cast(s32) it_index;
        p := month_period(it.month);
        it.closing = st.balances[clamp(min(p.last, app.today) - an.first_day, 0, an.day_count - 1)];
    }
    for * t: store.transactions {
        if !is_chosen(st, t.account) || !counts_as_flow(t) continue;
        i := last_month - t.month;
        if i < 0 || i >= st.months.count continue;
        m := *st.months[i];
        m.count += 1;
        if t.amount > 0 m.money_in += t.amount;
        else m.money_out -= t.amount;
    }
}

draw_account_flow :: (r: Rect, st: *Accounts_State) {
    if !chosen_count(st) {
        content, _ := panel_begin(r, "In and out by month");
        draw_empty_state(content, "No account selected");
        return;
    }
    content, _ := panel_begin(r, "In and out by month", tprint("% · last 12 months", chosen_name(st)));
    chart := rect_inset_xy(content, px(12), px(8));
    if !st.months.count { draw_empty_state(chart, "Loading…", "", .SYNC); return; }
    n := min(st.months.count, 12);
    buckets := NewArray(n, Flow_Bucket,, temp);
    for i: 0..n - 1 {
        m := st.months[n - 1 - i];
        p := month_period(m.month);
        buckets[i] = .{p.first, min(p.last, app.today), m.money_in, m.money_out, m.count};
    }
    draw_flow_chart(tprint("account-flow-%", chosen_key(st)), chart, buckets, app.today, monthly = true);
}

draw_account_chart :: (r: Rect, st: *Accounts_State) {
    if !chosen_count(st) {
        content, _ := panel_begin(r, "Balance");
        draw_empty_state(content, "No account selected", "Tick one or more accounts to see their balance together.");
        return;
    }
    period := range_period(st.range);
    start_balance := chosen_balance_at(st, period.first);
    end_balance: s64;
    for st.checked if it end_balance += store.accounts[it_index].balance;
    span := tprint("% → %", format_money(start_balance), format_money(end_balance));
    single := single_chosen(st);
    title := ifx single >= 0 then tprint("% balance", store.accounts[single].name) else "Combined balance";
    meta := ifx single >= 0 then span else tprint("% · %", chosen_name(st), span);
    content, header := panel_begin(r, title, meta);
    chart := rect_inset_xy(content, px(12), px(10));
    an := *analytics;
    if !store.transactions.count || st.balances.count != an.day_count {
        draw_empty_state(chart, "Loading history…", "", .SYNC);
        return;
    }
    first := max(period.first, an.first_day);
    n := app.today - first + 1;
    series := array_view(st.balances, first - an.first_day, n);
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
    count := chosen_count(st);
    if !count {
        content, _ := panel_begin(r, "By month");
        draw_empty_state(content, "No account selected");
        return;
    }
    // Transactions filters by one account or all of them.
    single := single_chosen(st);
    can_open := single >= 0 || count == store.accounts.count;
    notes: [..] string;
    notes.allocator = temp;
    if settings.exclude_transfers array_add(*notes, "excl. transfers between your accounts");
    if can_open array_add(*notes, "double-click a month");
    content, _ := panel_begin(r, tprint("% by month", chosen_name(st)), join(..notes, " · ",, temp));
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
    if tbl.activated >= 0 && can_open show_transactions(account = single, custom = month_period(st.months[tbl.activated].month));
}
