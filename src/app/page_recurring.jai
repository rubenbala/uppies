// Recurring: what comes round on a schedule, what it costs, and what is due.
//
// The series are worked out from the history (recurring.jai): the table
// lists them, the Upcoming panel shows the next 30 days, and the panel under
// it the chosen one in full, with its charges. A series that isn't really
// recurring can be hidden; it then counts towards nothing.

Recurring_Page_State :: struct {
    kind:        int;           // 0 all, 1 subscriptions, 2 bills, 3 income.
    show_ended:  bool = true;
    show_hidden: bool;
    table:       Table_State;
    rows:        [..] s32;      // Series, in display order.
    rows_key:    u64;
    selected:    u64;           // Series id: kept across recomputes.
    upcoming_table: Table_State;
    charges_table:  Table_State;
    initialized: bool;
}

RECURRING_FILTERS :: string.["All", "Subscriptions", "Bills", "Income"];

// Shows the Recurring page with this series chosen.
show_recurring :: (id: u64) {
    choose_series(*app.recurring_page, id);
    select_page(.RECURRING);
}

// Chooses a series, widening the table's filters when they leave it out
// (back to All from Subscriptions, say), so the table can show it chosen.
choose_series :: (st: *Recurring_Page_State, id: u64) {
    st.selected = id;
    s := recurring_find(id);
    if s >= 0 {
        series := *recurring.series[s];
        if st.kind != 0 && st.kind != cast(int) series.kind + 1 st.kind = 0;
        if !series.active st.show_ended = true;
        if series.hidden st.show_hidden = true;
    }
    st.rows_key = 0;
}

recurring_kind_color :: (kind: Recurring_Kind) -> Color {
    if kind == {
        case .SUBSCRIPTION; return theme.accent;
        case .BILL;         return theme.info;
    }
    return theme.positive;
}

// "Today", "Tomorrow", "Thu 8 Oct".
recurring_day_label :: (day: s64, today: s64) -> string {
    if day == today return "Today";
    if day == today + 1 return "Tomorrow";
    return format_weekday_date(day, today);
}

// A recent change of price on an active series (a rise or a cut), worth saying.
recurring_recent_change :: (s: *Recurring_Series, today: s64) -> bool {
    return s.active && !s.hidden && s.previous_amount > 0 && today - s.changed_day <= 45;
}

draw_recurring_page :: (r_in: Rect) {
    st := *app.recurring_page;
    if !st.initialized {
        st.initialized = true;
        st.table.sort_column = COL_PER_MONTH;
        st.table.sort_desc = true;
    }
    r := r_in;
    today := app.today;

    // Toolbar: kind, ended and hidden ones.
    bar := toolbar_rect(*r);
    changed := ui_segmented("recurring-kind", cut_left(*bar, ui_segmented_width(RECURRING_FILTERS)), RECURRING_FILTERS, *st.kind);
    cut_left(*bar, px(12));
    ended_label := "Show ended##recurring";
    if ui_checkbox(ended_label, cut_left(*bar, px(30) + measure_text(fonts.regular, px(theme.font_size_body), display_text(ended_label))), *st.show_ended) changed = true;
    if recurring.hidden_count || st.show_hidden {
        cut_left(*bar, px(8));
        hidden_label := tprint("Show hidden (%)##recurring", recurring.hidden_count);
        if ui_checkbox(hidden_label, cut_left(*bar, px(30) + measure_text(fonts.regular, px(theme.font_size_body), display_text(hidden_label))), *st.show_hidden) changed = true;
    }
    note := "Worked out from your transaction history";
    if measure_text(fonts.regular, px(theme.font_size_label), note) < bar.w - px(20) draw_text_in_rect(fonts.regular, px(theme.font_size_label), bar, note, theme.text_muted, .RIGHT);
    if changed st.table.scroll.target = 0;

    rebuild_rows(st);

    // The numbers.
    due := recurring_due(today, today + 30);
    due_out: s64;
    due_count := 0;
    for due {
        s := *recurring.series[it];
        if s.amount < 0 { due_out -= s.amount; due_count += 1; }
    }
    next_name := "";
    for due if recurring.series[it].amount < 0 {
        s := *recurring.series[it];
        next_name = tprint("next: % %", s.name, to_lower_temp(recurring_day_label(s.next_day, today)));
        break;
    }
    counts: [3] int;
    changes := 0;
    change_name := "";
    for * recurring.series {
        if !it.active || it.hidden continue;
        counts[it.kind] += 1;
        if recurring_recent_change(it, today) { changes += 1; change_name = it.name; }
    }
    loading := sync.phase == .LOADING && !sync.history_complete;
    yearly := (recurring.subscriptions_monthly + recurring.bills_monthly) * 12;
    strip := cut_top(*r, px(METRIC_STRIP_HEIGHT));
    cut_top(*r, px(8));
    metrics := Metric.[
        .{label = "Subscriptions", value = format_money(recurring.subscriptions_monthly), detail = tprint("a month · %", format_count(counts[0], "active", "active")), loading = loading},
        .{label = "Bills", value = format_money(recurring.bills_monthly), detail = tprint("a month · %", format_count(counts[1], "active", "active")), loading = loading},
        .{label = "Recurring income", value = format_money(recurring.income_monthly), value_color = ifx recurring.income_monthly then theme.positive else 0,
          detail = tprint("a month · %", format_count(counts[2], "source", "sources")), loading = loading},
        .{label = "Due in 30 days", value = format_money(due_out), detail = ifx due_count then tprint("% · %", format_count(due_count, "payment", "payments"), next_name) else "nothing due", loading = loading, roll_up = false},
        .{label = "Per year", value = format_money_whole(yearly), detail = "subscriptions and bills", loading = loading,
          tooltip = "What the active subscriptions and bills come to over a year at today's prices."},
        .{label = "Price changes", value = tprint("%", changes), value_color = ifx changes then theme.held else 0,
          detail = ifx changes == 1 then tprint("% · last 45 days", change_name) else "in the last 45 days", loading = loading},
    ];
    draw_metric_strip(appear_begin(strip, 0), metrics, "recurring-metrics");
    appear_end();

    left := cut_left(*r, r.w * 0.55);
    cut_left(*r, px(8));
    draw_series_table(appear_begin(left, 1), st);
    appear_end();
    upcoming_r := cut_top(*r, clamp(r.h * 0.36, px(170), px(280)));
    cut_top(*r, px(8));
    draw_upcoming(appear_begin(upcoming_r, 2), st, due);
    appear_end();
    draw_series_detail(appear_begin(r, 3), st);
    appear_end();
}

#scope_file

COL_NAME      :: 0;
COL_SCHEDULE  :: 1;
COL_AMOUNT    :: 2;
COL_PER_MONTH :: 3;
COL_NEXT      :: 4;
COL_ACCOUNT   :: 5;

SERIES_COLUMNS :: Column.[
    .{"Name",      0,   .LEFT,  true, 0},
    .{"Schedule",  108, .LEFT,  true, 520},
    .{"Amount",    104, .RIGHT, true, 0},
    .{"Per month", 96,  .RIGHT, true, 620},
    .{"Next",      96,  .RIGHT, true, 0},
    .{"Account",   120, .LEFT,  true, 760},
];

sort_column: int;

rebuild_rows :: (st: *Recurring_Page_State) {
    key := hash_key(recurring.key, cast(u64) st.kind, cast(u64) st.show_ended, cast(u64) st.show_hidden, cast(u64) (st.table.sort_column + 3), cast(u64) st.table.sort_desc);
    if key == st.rows_key return;
    st.rows_key = key;
    st.rows.count = 0;
    for recurring.series {
        if st.kind > 0 && cast(int) it.kind != st.kind - 1 continue;
        if !it.active && !st.show_ended continue;
        if it.hidden && !st.show_hidden continue;
        array_add(*st.rows, cast(s32) it_index);
    }
    sort_column = st.table.sort_column;
    quick_sort(st.rows, (a: s32, b: s32) -> int {
        x := *recurring.series[a];
        y := *recurring.series[b];
        c := 0;
        if sort_column == {
            case COL_NAME;      c = compare_strings(to_lower_temp(x.name), to_lower_temp(y.name));
            case COL_SCHEDULE;  c = cast(int) cadence_days(x.cadence) - cast(int) cadence_days(y.cadence);
            case COL_AMOUNT;    c = sign(abs(x.amount) - abs(y.amount));
            case COL_PER_MONTH; c = sign(x.monthly - y.monthly);
            case COL_NEXT;      c = sign(x.next_day - y.next_day);
            case;               c = compare_strings(account_name(*store, x.account), account_name(*store, y.account));
        }
        return ifx c != 0 then c else a - b;
    });
    if st.table.sort_desc {
        n := st.rows.count;
        for 0..n / 2 - 1 { st.rows[it], st.rows[n - 1 - it] = st.rows[n - 1 - it], st.rows[it]; }
    }
    // Whatever the order, what is still going comes before what has ended,
    // and the hidden ones last.
    rank :: (s: *Recurring_Series) -> int { return ifx s.hidden then 2 else ifx s.active then 0 else 1; }
    for i: 1..st.rows.count - 1 {
        j := i;
        while j > 0 && rank(*recurring.series[st.rows[j - 1]]) > rank(*recurring.series[st.rows[j]]) {
            st.rows[j - 1], st.rows[j] = st.rows[j], st.rows[j - 1];
            j -= 1;
        }
    }
}

sign :: (v: s64) -> int { return ifx v > 0 then 1 else ifx v < 0 then -1 else 0; }

// An amount that varies, as its typical figure in whole dollars: "−$311 avg".
draw_typical :: (r: Rect, cents: s64, faded := false) {
    w := draw_text_in_rect(fonts.regular, px(theme.font_size_label), r, "avg", theme.text_faint, .RIGHT);
    money := r;
    money.w -= w + px(4);
    color := ifx cents > 0 then theme.positive else ifx faded then theme.text_muted else theme.text;
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), money, format_money_whole(cents, .ALWAYS), color, .RIGHT, .{tabular = true});
}

draw_series_table :: (r: Rect, st: *Recurring_Page_State) {
    active, ended := 0, 0;
    for st.rows { if recurring.series[it].active active += 1; else ended += 1; }
    meta := format_count(active, "active", "active");
    if ended meta = tprint("% · % ended", meta, ended);
    content, _ := panel_begin(r, "Recurring", meta);

    selected_row := -1;
    for st.rows if recurring.series[it].id == st.selected selected_row = it_index;
    if selected_row < 0 && st.rows.count { selected_row = 0; st.selected = recurring.series[st.rows[0]].id; }
    st.table.selected = selected_row;

    tbl: Data_Table;
    table_begin(*tbl, "recurring-table", content, SERIES_COLUMNS, *st.table, st.rows.count, keyboard = true);
    if tbl.sort_changed st.rows_key = 0;
    if !st.rows.count {
        table_end(*tbl);
        if sync.phase == .LOADING && !store.transactions.count table_skeleton(*tbl, 8);
        else if !recurring.series.count draw_empty_state(content, "Nothing recurring found yet", "Subscriptions and bills show up once they've been charged a few times.", .SYNC);
        else draw_empty_state(content, "None of these", "Try All, or show the ended ones.", .SYNC);
        return;
    }
    today := app.today;
    for i: tbl.first..tbl.last {
        s := *recurring.series[st.rows[i]];
        row := table_row(*tbl, i);
        faded := !s.active || s.hidden;
        text_color := ifx faded then theme.text_muted else theme.text;

        name := table_cell(*tbl, row, COL_NAME);
        dot := snap(rect(name.x, name.y + (name.h - px(8)) * 0.5, px(8), px(8)));
        draw_rect(dot, color_with_alpha(recurring_kind_color(s.kind), ifx faded then 0.4 else 1.0), px(4));
        name_r := rect(name.x + px(16), name.y, name.w - px(16), name.h);
        if recurring_recent_change(s, today) {
            label := ifx abs(s.amount) > s.previous_amount then "Price up" else "Price down";
            w := measure_text(fonts.semibold, px(theme.font_size_small), label) + px(25);
            if name_r.w > w + px(60) {
                draw_chip(name_r.x + name_r.w - w, name_r.y + name_r.h * 0.5, label, theme.held, ifx abs(s.amount) > s.previous_amount then Icon.ARROW_UP else .ARROW_DOWN);
                name_r.w -= w + px(6);
            }
        }
        draw_text_fit(fonts.regular, px(theme.font_size_body), name_r, s.name, text_color);

        if table_column_shown(*tbl, COL_SCHEDULE) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, COL_SCHEDULE), CADENCE_LABELS[s.cadence], theme.text_secondary);
        amount_r := table_cell(*tbl, row, COL_AMOUNT);
        if s.variable draw_typical(amount_r, s.amount, faded);
        else draw_amount(amount_r, s.amount, muted = faded);
        if table_column_shown(*tbl, COL_PER_MONTH) draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, COL_PER_MONTH), format_money(s.monthly), theme.text_muted, .RIGHT, .{tabular = true});
        next_r := table_cell(*tbl, row, COL_NEXT);
        if s.hidden            draw_text_in_rect(fonts.regular, px(theme.font_size_label), next_r, "Hidden", theme.text_faint, .RIGHT);
        else if !s.active      draw_text_in_rect(fonts.regular, px(theme.font_size_label), next_r, "Ended", theme.text_faint, .RIGHT);
        else if s.next_day < today draw_text_in_rect(fonts.regular, px(theme.font_size_label), next_r, "Due", theme.held, .RIGHT);
        else draw_text_in_rect(fonts.regular, px(theme.font_size_label), next_r, ifx s.next_day <= today + 1 then recurring_day_label(s.next_day, today) else format_date_short(s.next_day, today), theme.text_secondary, .RIGHT, .{tabular = true});
        if table_column_shown(*tbl, COL_ACCOUNT) draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, COL_ACCOUNT), account_name(*store, s.account), theme.text_muted);
    }
    table_end(*tbl);
    if st.table.selected >= 0 && st.table.selected < st.rows.count st.selected = recurring.series[st.rows[st.table.selected]].id;
    if tbl.activated >= 0 open_in_transactions(*recurring.series[st.rows[tbl.activated]]);
}

UPCOMING_COLUMNS :: Column.[
    .{"Date",   112, .LEFT,  false, 0},
    .{"Name",   0,   .LEFT,  false, 0},
    .{"Amount", 104, .RIGHT, false, 0},
];

draw_upcoming :: (r: Rect, st: *Recurring_Page_State, due: [] s32) {
    out: s64;
    for due if recurring.series[it].amount < 0 out -= recurring.series[it].amount;
    content, _ := panel_begin(r, "Upcoming", ifx out then tprint("next 30 days · % out", format_money(out)) else "next 30 days");
    if !due.count {
        draw_empty_state(content, "Nothing due in the next 30 days", "", .CALENDAR);
        return;
    }
    // Picking one here picks it in the table; the highlight follows it.
    st.upcoming_table.selected = -1;
    for due if recurring.series[it].id == st.selected st.upcoming_table.selected = it_index;
    today := app.today;
    tbl: Data_Table;
    table_begin(*tbl, "recurring-upcoming", content, UPCOMING_COLUMNS, *st.upcoming_table, due.count, show_header = false);
    for i: tbl.first..tbl.last {
        s := *recurring.series[due[i]];
        row := table_row(*tbl, i);
        late := s.next_day < today;
        when := ifx late then tprint("Due %", format_date_column(s.next_day)) else recurring_day_label(s.next_day, today);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row, 0), when, ifx late then theme.held else theme.text_secondary, .LEFT, .{tabular = true});
        name := table_cell(*tbl, row, 1);
        dot := snap(rect(name.x, name.y + (name.h - px(8)) * 0.5, px(8), px(8)));
        draw_rect(dot, recurring_kind_color(s.kind), px(4));
        draw_text_fit(fonts.regular, px(theme.font_size_body), rect(name.x + px(16), name.y, name.w - px(16), name.h), s.name, theme.text);
        amount_r := table_cell(*tbl, row, 2);
        if s.variable draw_typical(amount_r, s.amount);
        else draw_amount(amount_r, s.amount);
    }
    table_end(*tbl);
    if tbl.clicked >= 0 choose_series(st, recurring.series[due[tbl.clicked]].id);
}

CHARGE_COLUMNS :: Column.[
    .{"Date",    112, .LEFT,  false, 0},
    .{"Account", 0,   .LEFT,  false, 0},
    .{"Amount",  104, .RIGHT, false, 0},
];

draw_series_detail :: (r: Rect, st: *Recurring_Page_State) {
    index := recurring_find(st.selected);
    if index < 0 {
        content, _ := panel_begin(r, "Details");
        draw_empty_state(content, "Choose one in the table", "", .SYNC);
        return;
    }
    s := *recurring.series[index];
    today := app.today;
    button_label := ifx s.hidden then "Show again##recurring" else "Not recurring##recurring";
    button_w := ui_button_width(button_label);
    link_w := px(130);
    content, header := panel_begin(r, s.name, RECURRING_KIND_LABELS[s.kind], controls = (button_w + link_w + px(10)) / ui.scale);
    button_r := rect(header.x + header.w - button_w, header.y + (header.h - px(24)) * 0.5, button_w, px(24));
    if ui_button(button_label, button_r, .GHOST,
                 tooltip = ifx s.hidden then "Count it again" else "Leave it out of the totals and the upcoming list") {
        was_hidden := s.hidden;
        if !was_hidden && !st.show_hidden {
            // It leaves the table: the one below it is chosen instead.
            at := -1;
            for st.rows if it == index at = it_index;
            if at >= 0 && at + 1 < st.rows.count st.selected = recurring.series[st.rows[at + 1]].id;
            else if at > 0 st.selected = recurring.series[st.rows[at - 1]].id;
        }
        recurring_set_hidden(s.id, !was_hidden);   // Recomputed next frame: s is as it was until then.
        app_toast(.INFO, ifx was_hidden then tprint("% counts again.", s.name) else tprint("% is hidden. Show hidden ones to bring it back.", s.name));
        st.rows_key = 0;
        return;   // The series moved: it's drawn again next frame.
    }
    if ui_link("Open in Transactions##recurring", rect(button_r.x - link_w - px(10), header.y, link_w, header.h)) open_in_transactions(s);

    inner := rect_inset_xy(content, px(14), px(10));
    y := inner.y;
    row :: (y: *float, inner: Rect, label: string, value: string, color: Color = 0) {
        draw_field(rect(inner.x, y.*, inner.w, px(22)), label, value, value_color = color);
        y.* += px(22);
    }
    if s.hidden {
        row(*y, inner, "Status", "Hidden: left out of every total", theme.text_muted);
    } else if !s.active {
        row(*y, inner, "Status", tprint("Ended · last charged %", format_date(s.last_day)), theme.text_muted);
    } else {
        days := s.next_day - today;
        when := ifx days < 0 then tprint("% · % late", format_weekday_date(s.next_day, today), format_count(-days, "day", "days"))
                else ifx days <= 1 then tprint("% · %", recurring_day_label(s.next_day, today), format_weekday_date(s.next_day, today))
                else tprint("% · in % days", format_weekday_date(s.next_day, today), days);
        row(*y, inner, "Next", when, ifx days < 0 then theme.held else 0);
    }
    amount := recurring_amount_text(s);
    if s.variable amount = tprint("% · between % and %", amount, format_money_whole(s.low), format_money_whole(s.high));
    row(*y, inner, "Amount", amount, ifx s.amount > 0 then theme.positive else 0);
    row(*y, inner, "Per month", tprint("% · % a year", format_money(s.monthly), format_money_whole(s.monthly * 12)));
    if s.previous_amount {
        direction := ifx abs(s.amount) > s.previous_amount then "Went up" else "Went down";
        row(*y, inner, "Price change", tprint("% from % to % on %", direction, format_money(s.previous_amount), format_money(abs(s.amount)), format_date(s.changed_day)),
            ifx recurring_recent_change(s, today) then theme.held else 0);
    }
    history := tprint("Since % · %", format_date(s.first_day), format_count(s.count, "charge", "charges"));
    if s.missed history = tprint("% · % missed", history, s.missed);
    row(*y, inner, "History", history);
    row(*y, inner, "Account", account_name(*store, s.account));
    if s.category >= 0 row(*y, inner, "Category", store.categories[s.category].name);

    // Each charge as a bar, oldest on the left: a price rise is a step, a
    // bill that varies is uneven.
    chart := rect(inner.x, y + px(10), inner.w, px(64));
    y = chart.y + chart.h + px(12);
    if chart.y + chart.h < content.y + content.h - px(60) {
        shown := min(s.count, 36);
        first := s.count - shown;
        biggest: s64 = 1;
        for k: first..s.count - 1 biggest = max(biggest, abs(store.transactions[recurring.members[s.first + k]].amount));
        gap := px(3);
        bar_w := min((chart.w - gap * (shown - 1)) / shown, px(18));
        color := recurring_kind_color(s.kind);
        ui_divider(chart.x, chart.y + chart.h, chart.w, theme.border);
        for k: first..s.count - 1 {
            t := *store.transactions[recurring.members[s.first + k]];
            h := max(chart.h * abs(t.amount) / cast(float) biggest, px(2));
            bar := snap(rect(chart.x + (k - first) * (bar_w + gap), chart.y + chart.h - h, bar_w, h));
            id := ui_id("recurring-bar", k);
            io := ui_interact(id, rect(bar.x, chart.y, bar_w + gap, chart.h));
            draw_rect(bar, color_with_alpha(color, ifx io.hovered then 1.0 else 0.7), px(2));
            ui_tooltip(id, io.hovered, tprint("%\t%", format_date(t.day), format_money(t.amount, .ALWAYS)));
            if io.hovered ui.cursor = .HAND;
            if io.clicked show_transactions(select_id = t.id);
        }
    }

    // The charges, newest first.
    list := rect(content.x, y, content.w, content.y + content.h - y);
    if list.h < px(60) return;
    tbl: Data_Table;
    table_begin(*tbl, tprint("recurring-charges-%", s.id), list, CHARGE_COLUMNS, *st.charges_table, s.count);
    for i: tbl.first..tbl.last {
        t := *store.transactions[recurring.members[s.first + s.count - 1 - i]];
        row_r := table_row(*tbl, i);
        draw_text_in_rect(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row_r, 0), format_weekday_date(t.day, today), theme.text_secondary, .LEFT, .{tabular = true});
        draw_text_fit(fonts.regular, px(theme.font_size_label), table_cell(*tbl, row_r, 1), account_name(*store, t.account), theme.text_muted);
        draw_amount(table_cell(*tbl, row_r, 2), t.amount);
    }
    table_end(*tbl);
    if tbl.activated >= 0 show_transactions(select_id = store.transactions[recurring.members[s.first + s.count - 1 - tbl.activated]].id);
}

// Its charges in Transactions, the latest open in the inspector.
open_in_transactions :: (s: *Recurring_Series) {
    latest := *store.transactions[recurring.members[s.first + s.count - 1]];
    show_transactions(search = s.name, account = s.account, select_id = latest.id);
}
