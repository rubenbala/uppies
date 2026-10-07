// Overview: where do I stand, what changed, and is anything waiting on me?

Overview_State :: struct {
    flow_range: int;   // 0: daily for 30 days, 1: weekly for 12 weeks.
    accounts_table: Table_State;
    recent_table:   Table_State;
    spend_table:    Table_State;
}

draw_overview_page :: (r_in: Rect) {
    st := *app.overview;
    r := r_in;
    cut_top(*r, px(10));
    a := *analytics;
    today := app.today;
    loading := sync.phase == .LOADING && !sync.history_complete;
    no_data := !store.accounts.count;

    // Headline numbers.
    this_month := month_key_from_day(today);
    month_index := this_month - a.first_month;
    month_out, month_in: s64;
    if month_index >= 0 && month_index < a.month_count { month_out = a.month_out[month_index]; month_in = a.month_in[month_index]; }
    // The same stretch of last month, for a fair comparison.
    day_of_month := civil_from_days(today).day;
    last_first := first_day_of_month(this_month - 1);
    last_same := Period.{last_first, min(last_first + day_of_month - 1, first_day_of_month(this_month) - 1)};
    last_flow := period_flow(last_same);

    total, spending, savers: s64;
    saver_count := 0;
    for store.accounts {
        total += it.balance;
        if it.type == .TRANSACTIONAL spending += it.balance;
        if it.type == .SAVER { savers += it.balance; saver_count += 1; }
    }
    month_ago := total_balance_at(today - 30);
    change := total - month_ago;

    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));
    cut_top(*r, px(8));
    out_delta := format_change_percent(month_out, last_flow.money_out);
    metrics := Metric.[
        .{label = "Net position", value = format_money(total), detail = tprint("% vs 30 days ago", format_money(change, .ALWAYS)), loading = no_data,
          tooltip = "Every account's balance added together, held amounts included."},
        .{label = "Spending accounts", value = format_money(spending), detail = "available now", loading = no_data},
        .{label = "Savers", value = format_money(savers), detail = format_count(saver_count, "saver", "savers"), loading = no_data},
        .{label = "On hold", value = format_money(-a.held_total), value_color = ifx a.held_count then theme.held else 0, detail = format_count(a.held_count, "transaction waiting", "transactions waiting"), loading = no_data},
        .{label = "Out this month", value = format_money(month_out), loading = loading && !store.transactions.count,
          delta = out_delta, delta_up = month_out >= last_flow.money_out, delta_good = ifx month_out > last_flow.money_out then -1 else 1,
          detail = tprint("vs % in %", format_money_whole(last_flow.money_out), period_label(last_same)), roll_up = false,
          tooltip = "Money out since the 1st, compared with the same days of last month."},
        .{label = "In this month", value = format_money(month_in), value_color = ifx month_in > 0 then theme.positive else 0,
          loading = loading && !store.transactions.count, detail = tprint("vs % in %", format_money_whole(last_flow.money_in), period_label(last_same))},
        .{label = "Net this month", value = format_money(month_in - month_out, .ALWAYS), value_color = ifx month_in > month_out then theme.positive else 0,
          loading = loading && !store.transactions.count, detail = ifx settings.exclude_transfers then "excl. own transfers" else "incl. own transfers"},
    ];
    draw_metric_strip(appear_begin(strip, 0), metrics, "overview-metrics");
    appear_end();

    gap := px(8);
    row1_h := max(px(250), (r.h - gap) * 0.56);
    row1 := cut_top(*r, row1_h);
    cut_top(*r, gap);
    row2 := r;

    left := cut_left(*row1, row1.w * 0.42);
    cut_left(*row1, gap);
    // The accounts table takes what its rows need; the net position trend
    // gets the rest.
    rows := max(store.accounts.count, 3);
    accounts_h := px(theme.panel_header_height + 26 + 2) + rows * px(theme.row_height);
    if left.h - accounts_h < px(130) accounts_h = left.h;
    accounts_r := cut_top(*left, accounts_h);
    draw_accounts_panel(appear_begin(accounts_r, 1), st);
    appear_end();
    if left.h > px(130) {
        cut_top(*left, gap);
        draw_net_position_panel(appear_begin(left, 2));
        appear_end();
    }
    draw_flow_panel(appear_begin(row1, 3), st);
    appear_end();

    spend_r := cut_left(*row2, row2.w * 0.33);
    cut_left(*row2, gap);
    attention_r := cut_right(*row2, row2.w * 0.36);
    cut_right(*row2, gap);
    draw_month_spend_panel(appear_begin(spend_r, 3), st);
    appear_end();
    draw_recent_panel(appear_begin(row2, 4), st);
    appear_end();
    draw_attention_panel(appear_begin(attention_r, 5));
    appear_end();
}

#scope_file

ACCOUNT_COLUMNS :: Column.[
    .{"Account", 0,   .LEFT,  false, 0},
    .{"Type",    96,  .LEFT,  false, 560},
    .{"30 days", 84,  .LEFT,  false, 470},
    .{"Change",  96,  .RIGHT, false, 0},
    .{"Balance", 112, .RIGHT, false, 0},
];

draw_accounts_panel :: (r: Rect, st: *Overview_State) {
    content, _ := panel_begin(r, "Accounts", ifx store.accounts.count then format_count(store.accounts.count, "account", "accounts") else "");
    order := account_order();
    tbl: Data_Table;
    table_begin(*tbl, "overview-accounts", content, ACCOUNT_COLUMNS, *st.accounts_table, order.count);
    if !store.accounts.count {
        table_end(*tbl);
        table_skeleton(*tbl, 5);
        return;
    }
    a := *analytics;
    for i: tbl.first..tbl.last {
        acct := order[i];
        account := *store.accounts[acct];
        row := table_row(*tbl, i);
        name := table_cell(*tbl, row, 0);
        draw_text_fit(fonts.regular, px(theme.font_size_body), name, account.name, theme.text);
        if table_column_shown(*tbl, 1) draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 1), account_type_label(account), theme.text_muted);
        if table_column_shown(*tbl, 2) && a.day_count > 30 {
            cell := table_cell(*tbl, row, 2);
            series := array_view(a.balance_hist, acct * a.day_count + a.day_count - 31, 31);
            draw_sparkline(rect(cell.x, cell.y + px(7), cell.w, cell.h - px(14)), series, theme.chart_line);
        }
        change := account.balance - balance_at(acct, app.today - 30);
        change_text := ifx change == 0 then "—" else format_money(change, .ALWAYS);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 3), change_text, ifx change > 0 then theme.positive else ifx change < 0 then theme.text_secondary else theme.text_faint, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_body), table_cell(*tbl, row, 4), format_money(account.balance), theme.text, .RIGHT, .{tabular = true});
    }
    table_end(*tbl);
    if tbl.clicked >= 0 show_account(order[tbl.clicked]);
}

draw_net_position_panel :: (r: Rect) {
    a := *analytics;
    days := 90;
    first := app.today - days + 1;
    series := NewArray(days, s64,, temp);
    for d: 0..days - 1 series[d] = total_balance_at(first + d);
    content, _ := panel_begin(r, "Net position · 90 days", ifx store.transactions.count then tprint("% → %", format_money_whole(series[0]), format_money_whole(series[days - 1])) else "");
    chart := rect_inset_xy(content, px(12), px(8));
    if !store.transactions.count || a.day_count < 2 { draw_empty_state(chart, "Loading…", "", .SYNC); return; }
    draw_balance_chart("net-position-90", chart, series, first, app.today, theme.chart_line);
}

draw_flow_panel :: (r: Rect, st: *Overview_State) {
    title := ifx st.flow_range == 0 then "Cash flow · last 30 days" else "Cash flow · last 12 weeks";
    content, header := panel_begin(r, title, ifx settings.exclude_transfers then "excl. transfers between your accounts" else "", controls = 120);
    options := string.["Days", "Weeks"];
    seg_w := ui_segmented_width(options);
    ui_segmented("flow-range", cut_right(*header, seg_w), options, *st.flow_range);

    chart := rect_inset_xy(content, px(12), px(8));
    a := *analytics;
    if !store.transactions.count {
        if sync.phase == .LOADING draw_empty_state(chart, "Loading transactions…", "", .SYNC);
        else draw_empty_state(chart, "No transactions yet");
        return;
    }
    buckets: [..] Flow_Bucket;
    buckets.allocator = temp;
    if st.flow_range == 0 {
        for d: app.today - 29..app.today {
            i := d - a.first_day;
            b := array_add(*buckets);
            b.first_day = d;
            b.last_day = d;
            if i >= 0 && i < a.day_count { b.money_in = a.day_in[i]; b.money_out = a.day_out[i]; b.count = a.day_txns[i]; }
        }
    } else {
        // Weeks ending on Sunday; the current week is partial.
        week_start := app.today - weekday_from_days(app.today);
        for w: 0..11 {
            first := week_start - (11 - w) * 7;
            b := array_add(*buckets);
            b.first_day = first;
            b.last_day = min(first + 6, app.today);
            for d: first..b.last_day {
                i := d - a.first_day;
                if i < 0 || i >= a.day_count continue;
                b.money_in += a.day_in[i];
                b.money_out += a.day_out[i];
                b.count += a.day_txns[i];
            }
        }
    }
    clicked := draw_flow_chart(ifx st.flow_range == 0 then "flow-days" else "flow-weeks", chart, buckets, app.today);
    _ = clicked;
}

draw_month_spend_panel :: (r: Rect, st: *Overview_State) {
    this_month := month_key_from_day(app.today);
    period := Period.{first_day_of_month(this_month), app.today};
    b := spend_breakdown(period);
    content, header := panel_begin(r, tprint("Spending in %", MONTH_LONG[month_key_month(this_month) - 1]), controls = 90, meta = ifx b.total > 0 then tprint("% · change vs %", format_money(b.total), period_label(b.previous)) else "");
    if ui_link("All categories##overview", rect(header.x + header.w - px(84), header.y, px(84), header.h)) select_page(.SPENDING);
    inner := rect_inset_xy(content, px(12), px(8));
    if !store.transactions.count { draw_empty_state(inner, "Loading…", "", .SYNC); return; }
    if b.total <= 0 { draw_empty_state(inner, "No spending yet this month"); return; }

    row_h := px(30);
    rows := min(b.rows.count, cast(int) (inner.h / row_h));
    biggest: s64 = 1;
    for b.rows biggest = max(biggest, it.spent);
    y := inner.y;
    for i: 0..rows - 1 {
        row := b.rows[i];
        if row.spent <= 0 continue;
        rr := rect(inner.x, y, inner.w, row_h);
        y += row_h;
        id := ui_id("month-spend", i);
        w := ui_widget(id);
        io := ui_interact(id, rr);
        if io.hovered ui.cursor = .HAND;
        ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 24);
        if w.hover > 0 draw_rect(snap(rect(rr.x - px(6), rr.y, rr.w + px(12), rr.h)), color_with_alpha(theme.hover, 0.55 * w.hover), px(2));
        name := ifx row.category >= 0 then store.categories[row.category].name else ifx row.category == -1 then "Uncategorised" else "Other payments";
        color := ifx row.category >= 0 then category_color(row.category) else UNCATEGORISED_COLOR;
        top := rect(rr.x, rr.y + px(2), rr.w, px(16));
        amount_w := px(84);
        draw_rect(snap(rect(top.x, top.y + px(4), px(8), px(8))), color, px(2));
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(top.x + px(14), top.y, top.w - amount_w - px(70), top.h), name, theme.text);
        delta := format_change_percent(row.spent, row.previous);
        if delta.count draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(top.x, top.y, top.w - amount_w - px(6), top.h), delta, theme.text_muted, .RIGHT, .{tabular = true});
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), top, format_money(row.spent), theme.text, .RIGHT, .{tabular = true});
        bar := rect(rr.x + px(14), rr.y + px(21), rr.w - px(14), px(4));
        // Bars grow in when the page appears.
        draw_share_bar(bar, cast(float) row.spent / cast(float) biggest * appear(3 + i), color);
        if io.clicked && row.category != -2 show_transactions(category = row.category, period = 1);
    }
}

RECENT_COLUMNS :: Column.[
    .{"Date",        64,  .LEFT,  false, 0},
    .{"Description", 0,   .LEFT,  false, 0},
    .{"Amount",      104, .RIGHT, false, 0},
];

draw_recent_panel :: (r: Rect, st: *Overview_State) {
    content, header := panel_begin(r, "Recent activity", controls = 104);
    if ui_link("All transactions##overview", rect(header.x + header.w - px(100), header.y, px(100), header.h)) show_transactions();
    n := min(store.transactions.count, 60);
    tbl: Data_Table;
    table_begin(*tbl, "overview-recent", content, RECENT_COLUMNS, *st.recent_table, n, show_header = false);
    if !store.transactions.count {
        table_end(*tbl);
        table_skeleton(*tbl, 8);
        return;
    }
    for i: tbl.first..tbl.last {
        t := *store.transactions[i];
        row := table_row(*tbl, i);
        age := ui.time - t.arrived_at;
        if age < 3.0 {
            draw_rect(snap(row), color_with_alpha(theme.accent_wash, cast(float) (1 - age / 3.0) * 1.6));
            ui.animating = true;
        }
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 0), format_date_short(t.day, app.today), theme.text_muted, .LEFT, .{tabular = true});
        desc := table_cell(*tbl, row, 1);
        if t.status == .HELD {
            cw := draw_chip(desc.x, desc.y + desc.h * 0.5, "Held", theme.held);
            cut_left(*desc, cw + px(8));
        }
        // Moves between your own accounts recede; purchases and income stand out.
        transfer := is_transfer(t);
        draw_text_fit(fonts.regular, px(theme.font_size_body), desc, t.description, ifx transfer then theme.text_muted else theme.text);
        draw_amount(table_cell(*tbl, row, 2), t.amount, muted = transfer);
    }
    table_end(*tbl);
    if tbl.clicked >= 0 show_transactions(select_id = store.transactions[tbl.clicked].id);
}

Attention_Action :: enum u8 { NONE; HELD; UNCATEGORISED; SETTINGS; WEBHOOKS; RECURRING; }

Attention_Item :: struct {
    icon:   Icon;
    color:  Color;
    title:  string;
    detail: string;
    action: Attention_Action;
    series: u64;   // RECURRING: the one to show.
}

draw_attention_panel :: (r: Rect) {
    items: [..] Attention_Item;
    items.allocator = temp;
    a := *analytics;
    if sync.auth_failed array_add(*items, .{.LOCK, theme.danger, "Access token rejected", "Up returned 401. Reconnect in Settings.", .SETTINGS, 0});
    else if sync.error.count array_add(*items, .{.WARNING, theme.held, "Last sync failed", sync.error, .SETTINGS, 0});
    if sync.phase == .LOADING array_add(*items, .{.SYNC, theme.info, tprint("Loading history · %", format_percent(sync_load_progress(), 0)), tprint("% transactions so far; totals fill in as it loads.", format_grouped(store.transactions.count)), .NONE, 0});
    if a.held_count array_add(*items, .{.CLOCK, theme.held, format_count(a.held_count, "transaction on hold", "transactions on hold"), tprint("% not yet settled", format_money(-a.held_total)), .HELD, 0});
    // Recurring: prices that went up lately, and what is due this week.
    for * recurring.series {
        if !recurring_recent_change(it, app.today) || abs(it.amount) <= it.previous_amount continue;
        array_add(*items, .{.ARROW_UP, theme.held, tprint("% went up to %", it.name, format_money(abs(it.amount))),
                            tprint("from % on % · %", format_money(it.previous_amount), format_date(it.changed_day), to_lower_temp(CADENCE_LABELS[it.cadence])), .RECURRING, it.id});
    }
    due_out: s64;
    due_names: [..] string;
    due_names.allocator = temp;
    first_due: u64;
    for recurring_due(app.today, app.today + 6) {
        s := *recurring.series[it];
        if s.amount >= 0 continue;
        if !due_names.count first_due = s.id;
        due_out -= s.amount;
        array_add(*due_names, s.name);
    }
    if due_names.count {
        names := join(..array_view(due_names, 0, min(due_names.count, 3)), ", ",, temp);
        if due_names.count > 3 names = tprint("%, …", names);
        array_add(*items, .{.CALENDAR, theme.info, format_count(due_names.count, "payment due this week", "payments due this week"), tprint("% · %", format_money(due_out), names), .RECURRING, first_due});
    }
    if a.uncategorised_count array_add(*items, .{.FILTER, theme.text_secondary, format_count(a.uncategorised_count, "uncategorised purchase", "uncategorised purchases"),
                                                tprint("% without a category, all time", format_money(-a.uncategorised_total)), .UNCATEGORISED, 0});
    if sync.webhooks_state == .LOADED && sync.logs_for.count {
        failed := 0;
        for sync.logs if it.delivery != .DELIVERED failed += 1;
        if failed array_add(*items, .{.LINK, theme.held, tprint("% failed webhook deliveries", failed), tprint("in the last % loaded", sync.logs.count), .WEBHOOKS, 0});
    }

    content, _ := panel_begin(r, "Needs attention", ifx items.count then tprint("%", items.count) else "");
    inner := rect_inset_xy(content, px(6), px(6));
    if !items.count {
        draw_empty_state(inner, "Nothing needs attention", "No holds, failures or uncategorised purchases.", .CHECK);
        return;
    }
    y := inner.y;
    for item, i: items {
        rr := rect(inner.x, y, inner.w, px(48));
        y += px(50);
        if rr.y + rr.h > inner.y + inner.h break;
        id := ui_id("attention", i);
        w := ui_widget(id);
        io := ui_interact(id, rr);
        clickable := item.action != .NONE;
        if io.hovered && clickable ui.cursor = .HAND;
        ui_animate(*w.hover, ifx io.hovered && clickable then 1.0 else 0.0, 24);
        draw_rect(snap(rr), color_with_alpha(theme.hover, 0.25 + 0.4 * w.hover), px(3));
        draw_rect(snap(rect(rr.x, rr.y, px(2), rr.h)), item.color);
        draw_icon(item.icon, rr.x + px(18), rr.y + px(16), px(12), item.color);
        draw_text_fit(fonts.semibold, px(theme.font_size_body), rect(rr.x + px(34), rr.y + px(6), rr.w - px(44), px(20)), item.title, theme.text);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(rr.x + px(34), rr.y + px(25), rr.w - px(44), px(17)), item.detail, theme.text_muted);
        if clickable draw_icon(.CHEVRON_RIGHT, rr.x + rr.w - px(12), rr.y + rr.h * 0.5, px(9), color_lerp(theme.text_faint, theme.text_secondary, w.hover));
        if io.clicked && clickable {
            if item.action == {
                case .HELD;          show_transactions(status = 1);
                case .UNCATEGORISED; show_transactions(category = -2);
                case .SETTINGS;      select_page(.SETTINGS);
                case .WEBHOOKS;      select_page(.WEBHOOKS);
                case .RECURRING;     show_recurring(item.series);
            }
        }
    }
}
