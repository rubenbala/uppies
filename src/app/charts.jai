// Charts, drawn with the same primitives as everything else.
//
// House style: hairline solid gridlines a step off the surface, compact
// money ticks on the left, bars no thicker than 24 px with a 4 px rounded
// data end and a square baseline end, 2 px lines with a faint area wash,
// labels in text colors (never the series color), a legend whenever there
// is more than one series, and a crosshair with a tooltip on hover. Values
// glide to their new heights when the data or the period changes.

Chart_Anim :: struct {
    values: [..] float;
    last_frame: u64;
}

chart_anims: Table(UI_Id, Chart_Anim);

// Animated copies of `targets` (same length), retained per chart. A new
// shape starts from `start` when given (same length), else from zero.
chart_animate :: (id: UI_Id, targets: [] float, speed := 12.0, start: [] float = .[]) -> [] float {
    anim := table_find_pointer(*chart_anims, id);
    if !anim anim = table_add(*chart_anims, id, .{});
    fresh := anim.values.count != targets.count;
    if fresh {
        array_resize(*anim.values, targets.count);
        if start.count == targets.count for * anim.values it.* = start[it_index];
        else for * anim.values it.* = 0;
    }
    anim.last_frame = ui.frame;
    for i: 0..targets.count - 1 ui_animate(*anim.values[i], targets[i], speed);
    return anim.values;
}

// A "nice" tick step for a range: 1, 2, 2.5 or 5 times a power of ten.
nice_step :: (range: float64, ticks: int) -> float64 {
    if range <= 0 return 1;
    raw := range / max(ticks, 1);
    magnitude := pow(10.0, floor(log10(raw)));
    for float64.[1, 2, 2.5, 5, 10] if raw <= it * magnitude return it * magnitude;
    return 10 * magnitude;
}

log10 :: (x: float64) -> float64 { return log(x) / log(10.0); }

AXIS_W :: 54.0;

draw_y_tick :: (plot: Rect, y: float, label: string, strong := false) {
    ui_divider(plot.x, y, plot.w, ifx strong then theme.border_strong else theme.grid);
    draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(plot.x - px(AXIS_W), y - px(8), px(AXIS_W - 8), px(16)), label, theme.text_muted, .RIGHT, .{tabular = true});
}

legend_item :: (x: float, cy: float, color: Color, label: string) -> float {
    draw_rect(snap(rect(x, cy - px(4), px(8), px(8))), color, px(2));
    w := draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(x + px(13), cy - px(8), px(200), px(16)), label, theme.text_secondary);
    return px(13) + w + px(14);
}

//
// Money in and out per bucket (days or weeks), in above the baseline and
// out below it.
//

Flow_Bucket :: struct {
    first_day: s64;
    last_day:  s64;
    money_in:  s64;
    money_out: s64;
    count:     int;
}

// Returns the bucket clicked, or -1.
// Buckets are days or weeks, or whole months with `monthly`.
draw_flow_chart :: (label: string, r: Rect, buckets: [] Flow_Bucket, today: s64, monthly := false) -> int {
    id := ui_id(label);
    n := buckets.count;
    if n == 0 return -1;

    legend := cut_top(*r, px(22));
    lx := legend.x + px(AXIS_W);
    lx += legend_item(lx, legend.y + legend.h * 0.5, theme.chart_in, "Money in");
    legend_item(lx, legend.y + legend.h * 0.5, theme.chart_out, "Money out");

    plot := r;
    cut_left(*plot, px(AXIS_W));
    labels := cut_bottom(*plot, px(18));
    plot = rect_inset_xy(plot, 0, px(6));

    targets := NewArray(n * 2, float,, temp);
    max_in, max_out: s64;
    for buckets {
        max_in = max(max_in, it.money_in);
        max_out = max(max_out, it.money_out);
        targets[it_index * 2] = cast(float) it.money_in;
        targets[it_index * 2 + 1] = cast(float) it.money_out;
    }
    values := chart_animate(id, targets);

    // Shared scale; the baseline sits where the two halves meet.
    top_range := max(cast(float64) max_in, 1.0);
    bottom_range := max(cast(float64) max_out, 1.0);
    step := nice_step((top_range + bottom_range) / 100.0, 4) * 100.0;
    top_range = ceil(top_range / step) * step;
    bottom_range = ceil(bottom_range / step) * step;
    total := top_range + bottom_range;
    base_y := plot.y + plot.h * cast(float) (top_range / total);
    scale := plot.h / cast(float) total;

    v := step;
    while v <= top_range + 1 { draw_y_tick(plot, base_y - cast(float) v * scale, format_money_compact(cast(s64) v)); v += step; }
    v = step;
    while v <= bottom_range + 1 { draw_y_tick(plot, base_y + cast(float) v * scale, format_money_compact(cast(s64) -v)); v += step; }
    draw_y_tick(plot, base_y, "$0", true);

    slot := plot.w / n;
    bar_w := clamp(slot * 0.62, px(1), px(24));
    radius := min(px(4), bar_w * 0.5);
    hovered := -1;
    clicked := -1;
    io := ui_interact(id, plot);
    if io.hovered hovered = clamp(cast(int) ((input.mouse_x - plot.x) / slot), 0, n - 1);
    if io.clicked && hovered >= 0 clicked = hovered;

    if hovered >= 0 draw_rect(snap(rect(plot.x + hovered * slot, plot.y, slot, plot.h)), color_with_alpha(theme.hover, 0.6));

    for b, i: buckets {
        cx := plot.x + (i + 0.5) * slot;
        x := cx - bar_w * 0.5;
        hin := values[i * 2] * scale;
        hout := values[i * 2 + 1] * scale;
        dim := hovered >= 0 && hovered != i;
        cin := ifx dim then color_lerp(theme.chart_in, theme.panel, 0.45) else theme.chart_in;
        cout := ifx dim then color_lerp(theme.chart_out, theme.panel, 0.45) else theme.chart_out;
        if hin >= 0.5 draw_rect_ex(rect(x, base_y - hin, bar_w, hin), cin, cin, .[radius, radius, 0, 0]);
        if hout >= 0.5 draw_rect_ex(rect(x, base_y + px(1), bar_w, hout), cout, cout, .[0, 0, radius, radius]);
    }

    // X labels: as many as fit without crowding.
    label_every := max(1, cast(int) ceil(px(ifx monthly then 40.0 else 56.0) / slot));
    for b, i: buckets {
        if (n - 1 - i) % label_every != 0 continue;
        d := civil_from_days(b.first_day);
        text := tprint("% %", d.day, MONTH_SHORT[d.month - 1]);
        if monthly {
            text = MONTH_SHORT[d.month - 1];
            if d.month == 1 || i == 0 text = tprint("% '%", text, pad2(d.year % 100));
        } else if b.first_day == today text = "Today";
        draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(plot.x + i * slot + slot * 0.5 - px(40), labels.y, px(80), labels.h), text, theme.text_muted, .CENTER);
    }

    if hovered >= 0 {
        b := buckets[hovered];
        when := ifx b.last_day > b.first_day then tprint("% – %", format_date(b.first_day), format_date(b.last_day)) else format_weekday_date(b.first_day, today);
        if monthly {
            d := civil_from_days(b.first_day);
            when = tprint("% %", MONTH_LONG[d.month - 1], d.year);
            if b.last_day == today when = tprint("% (so far)", when);
        }
        tip := tprint("%\nIn\t%\nOut\t%\nNet\t%\nTransactions\t%", when,
            format_money(b.money_in, .ALWAYS), format_money(-b.money_out), format_money(b.money_in - b.money_out, .ALWAYS),
            b.count);
        draw_tooltip(input.mouse_x, input.mouse_y, tip, 1, px(170));
    }
    return clicked;
}

//
// Monthly spending stacked by parent category, oldest on the left.
//

Month_Stack :: struct {
    month:    s32;
    segments: [5] s64;   // Up's four parents in order, then uncategorised/other.
}

draw_month_stack :: (label: string, r: Rect, months: [] Month_Stack, selected_month: s32, parent_names: [4] string) -> clicked_month: s32 {
    id := ui_id(label);
    n := months.count;
    if n == 0 return -1;

    legend := cut_top(*r, px(22));
    lx := legend.x + px(AXIS_W);
    for 0..3 lx += legend_item(lx, legend.y + legend.h * 0.5, parent_category_color(it), parent_names[it]);
    legend_item(lx, legend.y + legend.h * 0.5, theme.uncategorised, "Other");

    plot := r;
    cut_left(*plot, px(AXIS_W));
    labels := cut_bottom(*plot, px(18));
    plot = rect_inset_xy(plot, 0, px(6));

    targets := NewArray(n * 5, float,, temp);
    max_total: s64;
    for m, i: months {
        total: s64;
        for s, k: m.segments { v := max(s, 0); targets[i * 5 + k] = cast(float) v; total += v; }
        max_total = max(max_total, total);
    }
    values := chart_animate(id, targets);
    step := nice_step(cast(float64) max(max_total, 100) / 100.0, 4) * 100.0;
    top := ceil(max(cast(float64) max_total, 1.0) / step) * step;
    scale := plot.h / cast(float) top;
    v := step;
    while v <= top + 1 { draw_y_tick(plot, plot.y + plot.h - cast(float) v * scale, format_money_compact(cast(s64) v)); v += step; }
    draw_y_tick(plot, plot.y + plot.h, "$0", true);

    slot := plot.w / n;
    bar_w := clamp(slot * 0.6, px(2), px(24));
    radius := min(px(4), bar_w * 0.5);
    gap := px(2);
    io := ui_interact(id, plot);
    hovered := -1;
    if io.hovered {
        hovered = clamp(cast(int) ((input.mouse_x - plot.x) / slot), 0, n - 1);
        ui.cursor = .HAND;
    }
    clicked: s32 = -1;
    if io.clicked && hovered >= 0 clicked = months[hovered].month;

    for m, i: months {
        col := rect(plot.x + i * slot, plot.y, slot, plot.h);
        if m.month == selected_month draw_rect(snap(col), theme.accent_wash);
        else if hovered == i draw_rect(snap(col), color_with_alpha(theme.hover, 0.6));
        x := col.x + (slot - bar_w) * 0.5;
        y := plot.y + plot.h;
        // Find the topmost non-empty segment: only it gets the rounded end.
        top_k := -1;
        for k: 0..4 if values[i * 5 + k] * scale >= 1 top_k = k;
        for k: 0..4 {
            h := values[i * 5 + k] * scale;
            if h < 1 continue;
            seg_h := max(h - ifx k == top_k then 0.0 else gap, 1.0);
            color := parent_category_color(k);
            if hovered >= 0 && hovered != i && m.month != selected_month color = color_lerp(color, theme.panel, 0.4);
            rr := ifx k == top_k then radius else 0.0;
            draw_rect_ex(rect(x, y - h, bar_w, seg_h), color, color, .[rr, rr, 0, 0]);
            y -= h;
        }
        label_every := max(1, cast(int) ceil(px(34) / slot));
        if (n - 1 - i) % label_every == 0 {
            mm := month_key_month(m.month);
            text := MONTH_SHORT[mm - 1];
            if mm == 1 || i == 0 text = tprint("% '%", text, pad2(month_key_year(m.month) % 100));
            draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(col.x - px(20), labels.y, col.w + px(40), labels.h), text,
                              ifx m.month == selected_month then theme.text else theme.text_muted, .CENTER);
        }
    }

    if hovered >= 0 {
        m := months[hovered];
        builder: String_Builder;
        builder.allocator = temp;
        total: s64;
        for m.segments total += max(it, 0);
        print_to_builder(*builder, "% %", MONTH_LONG[month_key_month(m.month) - 1], month_key_year(m.month));
        print_to_builder(*builder, "\nTotal\t%", format_money(total));
        for k: 0..3 if m.segments[k] > 0 print_to_builder(*builder, "\n%\t%", parent_names[k], format_money(m.segments[k]));
        if m.segments[4] > 0 print_to_builder(*builder, "\nOther\t%", format_money(m.segments[4]));
        draw_tooltip(input.mouse_x, input.mouse_y, builder_to_string(*builder,, temp), 1, px(190));
    }
    return clicked;
}

//
// Balance over time: a 2 px line with a faint wash beneath, one point per day.
//

draw_balance_chart :: (label: string, r: Rect, balances: [] s64, first_day: s64, today: s64, color: Color) {
    id := ui_id(label);
    n := balances.count;
    if n < 2 {
        draw_empty_state(r, "Not enough history yet");
        return;
    }
    plot := r;
    cut_left(*plot, px(AXIS_W));
    labels := cut_bottom(*plot, px(18));
    plot = rect_inset_xy(plot, 0, px(8));

    // A line shows change, so the axis fits the data (with some air)
    // rather than starting at zero; it does include zero when it's near.
    lo, hi := balances[0], balances[0];
    for balances { lo = min(lo, it); hi = max(hi, it); }
    span := max(cast(float64) (hi - lo), 100.0);
    if lo > 0 && cast(float64) lo < span * 1.5 lo = 0;
    tick_span := max(cast(float64) (hi - lo), 100.0);
    step := nice_step(tick_span / 100.0, 4) * 100.0;
    axis_lo := floor(cast(float64) lo / step) * step;
    axis_hi := ceil(cast(float64) hi / step) * step;
    if axis_hi <= axis_lo axis_hi = axis_lo + step;

    // The axis glides with the line (same array, same speed), so every
    // in-between frame is a blend of two in-bounds frames and the line
    // never leaves the plot. A new shape grows from zero, so its axis
    // starts out wide enough to hold zero.
    targets := NewArray(n + 3, float,, temp);
    start := NewArray(n + 3, float,, temp);
    for balances targets[it_index] = cast(float) it;
    targets[n], targets[n + 1], targets[n + 2] = cast(float) axis_lo, cast(float) axis_hi, cast(float) tick_span;
    start[n], start[n + 1], start[n + 2] = cast(float) min(axis_lo, 0.0), cast(float) max(axis_hi, 0.0), cast(float) tick_span;
    animated := chart_animate(id, targets, 22, start);
    values := array_view(animated, 0, n);
    axis_lo = animated[n];
    axis_hi = max(cast(float64) animated[n + 1], axis_lo + 1);
    step = nice_step(max(cast(float64) animated[n + 2], 100.0) / 100.0, 4) * 100.0;

    scale := plot.h / cast(float) (axis_hi - axis_lo);
    y_of :: (value: float, plot: Rect, axis_lo: float64, scale: float) -> float {
        return plot.y + plot.h - (value - cast(float) axis_lo) * scale;
    }
    v := ceil(axis_lo / step - 0.001) * step;
    while v <= axis_hi + 1 {
        draw_y_tick(plot, y_of(cast(float) v, plot, axis_lo, scale), format_money_compact(cast(s64) v), abs(v) < step * 0.001);
        v += step;
    }

    dx := plot.w / (n - 1);
    base := y_of(cast(float) max(axis_lo, 0.0), plot, axis_lo, scale);
    wash_top := color_with_alpha(color, 0.16);
    wash_bottom := color_with_alpha(color, 0.02);
    for i: 0..n - 2 {
        x0 := plot.x + i * dx;
        y0 := y_of(values[i], plot, axis_lo, scale);
        y1 := y_of(values[i + 1], plot, axis_lo, scale);
        draw_area(x0, x0 + dx, y0, y1, base, wash_top, wash_bottom);
    }
    for i: 0..n - 2 {
        x0 := plot.x + i * dx;
        draw_line(x0, y_of(values[i], plot, axis_lo, scale), x0 + dx, y_of(values[i + 1], plot, axis_lo, scale), px(2), color);
    }

    // X labels: months (or days for short ranges).
    last_label_x := -1000.0;
    for i: 0..n - 1 {
        day := first_day + i;
        d := civil_from_days(day);
        mark := ifx n > 120 then d.day == 1 else (n > 31 && weekday_from_days(day) == 0) || (n <= 31 && (n - 1 - i) % 5 == 0);
        if !mark continue;
        x := plot.x + i * dx;
        if x - last_label_x < px(60) continue;
        last_label_x = x;
        text := ifx n > 120 then (ifx d.month == 1 then tprint("% %", MONTH_SHORT[0], d.year) else MONTH_SHORT[d.month - 1]) else tprint("% %", d.day, MONTH_SHORT[d.month - 1]);
        ui_vdivider(x, plot.y, plot.h, theme.grid);
        draw_text_in_rect(fonts.regular, px(theme.font_size_small), rect(x - px(40), labels.y, px(80), labels.h), text, theme.text_muted, .CENTER);
    }

    // End point and crosshair.
    end_y := y_of(values[n - 1], plot, axis_lo, scale);
    draw_circle(plot.x + plot.w, end_y, px(4) + px(2), theme.panel);
    draw_circle(plot.x + plot.w, end_y, px(4), color);

    io := ui_interact(id, plot);
    if io.hovered {
        i := clamp(cast(int) ((input.mouse_x - plot.x) / dx + 0.5), 0, n - 1);
        x := plot.x + i * dx;
        y := y_of(values[i], plot, axis_lo, scale);
        ui_vdivider(x, plot.y, plot.h, theme.text_faint);
        draw_circle(x, y, px(6), theme.panel);
        draw_circle(x, y, px(4), color);
        change := ifx i > 0 then balances[i] - balances[i - 1] else 0;
        tip := tprint("%\nBalance\t%\nThat day\t%", format_weekday_date(first_day + i, today), format_money(balances[i]), ifx change then format_money(change, .ALWAYS) else "no change");
        draw_tooltip(input.mouse_x, input.mouse_y, tip, 1, px(170));
    }
}

// A tiny line for table cells.
draw_sparkline :: (r: Rect, values: [] s64, color: Color) {
    n := values.count;
    if n < 2 return;
    lo, hi := values[0], values[0];
    for values { lo = min(lo, it); hi = max(hi, it); }
    span := max(cast(float) (hi - lo), 1.0);
    dx := r.w / (n - 1);
    for i: 0..n - 2 {
        y0 := r.y + r.h - (cast(float) (values[i] - lo) / span) * r.h;
        y1 := r.y + r.h - (cast(float) (values[i + 1] - lo) / span) * r.h;
        draw_line(r.x + i * dx, y0, r.x + (i + 1) * dx, y1, px(1.25), color);
    }
}
