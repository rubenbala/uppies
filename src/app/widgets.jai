// The console's building blocks: panels with compact headers, the metric
// strip, tables (virtualized, sortable, keyboard driven), chips and the
// small typographic helpers every page shares.

//
// Entrance: panels rise a few pixels and fade in, one after another, when a
// page appears.
//

appear :: (index: int) -> float {
    if ui.motion <= 0 return 1;
    t := (app.page_age - 0.03 - index * 0.045) / 0.32;
    if t < 1 ui.animating = true;
    return ease_out_cubic(t);
}

// Offsets r for the entrance and pushes its fade; pair with appear_end.
appear_begin :: (r: Rect, index: int) -> Rect {
    t := appear(index);
    push_opacity(t);
    result := r;
    result.y += px(6) * (1 - t);
    return result;
}

appear_end :: () { pop_opacity(); }

//
// Panels.
//

// A bordered panel with a header bar; returns the content area and the
// header (for controls on its right).
// `controls` (logical units) is kept free on the right of the header for
// buttons or links the caller adds there.
panel_begin :: (r: Rect, title: string, meta := "", meta_color: Color = 0, controls := 0.0) -> content: Rect, header: Rect {
    p := snap(r);
    draw_rect_outline(p, theme.panel, theme.border, hairline(), px(theme.radius_panel));
    header := rect(p.x, p.y, p.w, px(theme.panel_header_height));
    draw_rect_ex(rect_inset(header, hairline()), theme.panel_header, theme.panel_header, .[px(theme.radius_panel) - 1, px(theme.radius_panel) - 1, 0, 0]);
    ui_divider(p.x, header.y + header.h - hairline(), p.w, theme.border);
    text_r := rect_inset_xy(header, px(12), 0);
    tw := draw_caps(text_r, title, theme.text_secondary);
    if meta.count {
        meta_r := text_r;
        cut_left(*meta_r, tw + px(10));
        meta_r.w -= px(controls) + ifx controls > 0 then px(10) else 0.0;
        draw_text_fit(fonts.regular, px(theme.font_size_label), meta_r, meta, ifx meta_color then meta_color else theme.text_muted);
    }
    content := rect(p.x, header.y + header.h, p.w, p.h - header.h);
    header_controls := rect_inset_xy(header, px(6), px(3));
    header_controls.x += tw + px(12);
    header_controls.w -= tw + px(12);
    return content, header_controls;
}

// A message in the middle of an empty area.
draw_empty_state :: (r: Rect, title: string, detail := "", icon := Icon.INFO) {
    cy := r.y + r.h * 0.5;
    has_detail := detail.count > 0;
    top := cy - ifx has_detail then px(26) else px(14);
    draw_icon(icon, r.x + r.w * 0.5, top, px(16), theme.text_faint);
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), rect(r.x, top + px(12), r.w, px(20)), title, theme.text_secondary, .CENTER);
    if has_detail draw_text_fit(fonts.regular, px(theme.font_size_label), rect(r.x + px(16), top + px(32), r.w - px(32), px(18)), detail, theme.text_muted, .CENTER);
}

// A shimmering placeholder bar, for content still loading.
draw_skeleton :: (r: Rect, phase := 0.0) {
    t := cast(float) fmod_cycling(ui.time * 0.8 + phase, 1.0);
    base := theme.raised;
    hi := theme.hover;
    draw_rect(snap(r), color_lerp(base, hi, 0.5 + 0.5 * sin(cast(float) (t * TAU))), px(2));
    ui.animating = true;
}

//
// Metric strip: the numbers that answer "where do I stand", in a row of
// cells under the toolbar.
//

Metric :: struct {
    label:  string;
    value:  string;
    detail: string;
    value_color: Color;
    detail_color: Color;
    delta:  string;   // "+12%": shown before the detail with an arrow.
    delta_good: int;  // 1: the change is good news, -1: bad, 0: neither.
    delta_up: bool;
    roll_up := true;  // Direction new digits come from.
    tooltip: string;
    loading: bool;
}

METRIC_STRIP_HEIGHT :: 80.0;
// Label, value and detail rows, top to bottom, centered in the strip.
METRIC_CONTENT_HEIGHT :: 60.0;

draw_metric_strip :: (r: Rect, metrics: [] Metric, id_base: string) {
    strip := snap(r);
    draw_rect_outline(strip, theme.panel, theme.border, hairline(), px(theme.radius_panel));
    n := metrics.count;
    if !n return;
    cell_w := strip.w / n;
    // One figure size for the whole strip: the largest that fits every value.
    size := px(theme.font_size_metric);
    min_size := px(14);
    while size > min_size {
        fits := true;
        for metrics if !it.loading && measure_text(fonts.numeric, size, it.value, .{tabular = true}) > cell_w - px(28) { fits = false; break; }
        if fits break;
        size -= px(1);
    }
    for m, i: metrics {
        cell := rect(strip.x + i * cell_w, strip.y, cell_w, strip.h);
        if i > 0 ui_vdivider(cell.x, cell.y + px(10), cell.h - px(20), theme.border);
        inner := rect_inset_xy(cell, px(16), floor((cell.h - px(METRIC_CONTENT_HEIGHT)) * 0.5));
        cid := ui_id(id_base, i);
        if m.tooltip.count {
            io := ui_interact(cid, cell);
            ui_tooltip(cid, io.hovered, m.tooltip);
        }
        draw_caps(rect(inner.x, inner.y, inner.w, px(12)), m.label, theme.text_muted);
        value_r := rect(inner.x, inner.y + px(16), inner.w, px(26));
        if m.loading {
            draw_skeleton(rect(value_r.x, value_r.y + px(6), min(px(110), value_r.w * 0.7), px(14)), i * 0.15);
        } else {
            vw := draw_rolling_text(ui_id_combine(cid, 0x77), fonts.numeric, size, value_r, fit_text(fonts.numeric, size, m.value, value_r.w, .{tabular = true}),
                                    ifx m.value_color then m.value_color else theme.text, .LEFT, ifx m.roll_up then 1.0 else -1.0, .{tabular = true});
        }
        detail_r := rect(inner.x, inner.y + px(45), inner.w, px(15));
        if m.delta.count {
            arrow_color := ifx m.delta_good > 0 then theme.positive else ifx m.delta_good < 0 then theme.held else theme.text_muted;
            draw_icon(ifx m.delta_up then Icon.ARROW_UP else .ARROW_DOWN, detail_r.x + px(5), detail_r.y + detail_r.h * 0.5, px(9), arrow_color);
            dw := draw_text_in_rect(fonts.semibold, px(theme.font_size_label), rect(detail_r.x + px(13), detail_r.y, detail_r.w, detail_r.h), m.delta, theme.text_secondary, .LEFT, .{tabular = true});
            cut_left(*detail_r, px(13) + dw + px(6));
        }
        if m.detail.count draw_text_fit(fonts.regular, px(theme.font_size_label), detail_r, m.detail, ifx m.detail_color then m.detail_color else theme.text_muted);
    }
}

//
// Tables.
//

Column :: struct {
    title:     string;
    width:     float;          // Logical units; 0 shares what is left.
    align:     Text_Align = .LEFT;
    sortable:  bool = true;
    hide_below: float;         // Hidden when the table is narrower (logical units).
}

Table_State :: struct {
    scroll:      Scroll;
    sort_column: int = -1;
    sort_desc:   bool = true;
    selected:    int = -1;     // Row, in display order.
    sel_spring:  Spring;
    sel_alpha:   float;
}

MAX_COLUMNS :: 16;

Data_Table :: struct {
    id:     UI_Id;
    state:  *Table_State;
    rect:   Rect;
    header: Rect;
    body:   Rect;
    cols:   [] Column;
    x:      [MAX_COLUMNS] float;
    w:      [MAX_COLUMNS] float;
    shown:  [MAX_COLUMNS] bool;
    row_h:  float;
    count:  int;
    offset: float;
    first:  int;
    last:   int;

    clicked:   int = -1;   // Row clicked this frame.
    activated: int = -1;   // Row double-clicked or Enter'd.
    sort_changed:      bool;
    selection_changed: bool;
    hovered_row: int = -1;
    highlight:   bool;
}

CELL_PAD :: 10.0;

// Without `highlight` the selected row is still the keyboard's position, but
// isn't marked: the caller marks rows itself (when several can be chosen).
table_begin :: (t: *Data_Table, label: string, r: Rect, cols: [] Column, state: *Table_State, row_count: int, keyboard := false, row_height := 0.0, show_header := true, highlight := true) {
    t.id = ui_id(label);
    t.highlight = highlight;
    t.state = state;
    t.rect = r;
    t.cols = cols;
    t.count = row_count;
    t.row_h = ifx row_height > 0 then row_height else px(theme.row_height);
    t.clicked = -1;
    t.activated = -1;
    t.hovered_row = -1;
    t.sort_changed = false;
    t.selection_changed = false;

    area := r;
    t.header = ifx show_header then cut_top(*area, px(26)) else .{};
    t.body = area;

    // Column layout: fixed widths first, the rest shared by flexible ones.
    logical_w := r.w / ui.scale;
    fixed: float;
    flexible := 0;
    for c, i: cols {
        if i >= MAX_COLUMNS break;
        t.shown[i] = !(c.hide_below > 0 && logical_w < c.hide_below);
        if !t.shown[i] continue;
        if c.width > 0 fixed += px(c.width); else flexible += 1;
    }
    left := max(r.w - fixed - px(10), 0.0);   // 10: room for the scrollbar.
    x := r.x;
    for c, i: cols {
        if i >= MAX_COLUMNS break;
        if !t.shown[i] { t.w[i] = 0; t.x[i] = x; continue; }
        w := ifx c.width > 0 then px(c.width) else left / max(flexible, 1);
        t.x[i] = x;
        t.w[i] = w;
        x += w;
    }

    // Header: sortable titles; the sorted one shows its direction.
    if show_header {
        h := snap(t.header);
        ui_divider(h.x, h.y + h.h - hairline(), h.w, theme.border);
        for c, i: cols {
            if i >= MAX_COLUMNS || !t.shown[i] continue;
            cell := rect(t.x[i], h.y, t.w[i], h.h);
            text_r := rect_inset_xy(cell, px(CELL_PAD), 0);
            sorted := state.sort_column == i;
            hid := ui_id_combine(t.id, cast(u64) i + 500);
            hover := false;
            if c.sortable {
                hw := ui_widget(hid);
                io := ui_interact(hid, cell);
                hover = io.hovered;
                if io.hovered ui.cursor = .HAND;
                ui_animate(*hw.hover, ifx io.hovered then 1.0 else 0.0, 24);
                if hw.hover > 0 draw_rect(cell, color_with_alpha(theme.hover, 0.5 * hw.hover));
                if io.clicked {
                    if sorted state.sort_desc = !state.sort_desc;
                    else { state.sort_column = i; state.sort_desc = c.align == .RIGHT; }
                    t.sort_changed = true;
                }
            }
            color := ifx sorted then theme.text_secondary else ifx hover then theme.text_secondary else theme.text_muted;
            title := to_upper_temp(c.title);
            tw := measure_caps(c.title);
            if c.align == .RIGHT {
                if sorted {
                    draw_icon(ifx state.sort_desc then Icon.ARROW_DOWN else .ARROW_UP, text_r.x + text_r.w - px(4), text_r.y + text_r.h * 0.5, px(8), theme.accent);
                    text_r.w -= px(12);
                }
                draw_caps(text_r, c.title, color, .RIGHT);
            } else {
                draw_caps(text_r, c.title, color);
                if sorted draw_icon(ifx state.sort_desc then Icon.ARROW_DOWN else .ARROW_UP, text_r.x + tw + px(8), text_r.y + text_r.h * 0.5, px(8), theme.accent);
            }
            _ = title;
        }
    }

    // Keyboard: arrows, paging, Home/End, Enter.
    if keyboard && !ui.text_focus_prev && !ui.popup && !ui.modal_prev && row_count > 0 {
        sel := state.selected;
        page := max(cast(int) (t.body.h / t.row_h) - 1, 1);
        moved := false;
        if key_pressed(.DOWN)      { sel = ifx sel < 0 then 0 else min(sel + 1, row_count - 1); moved = true; }
        if key_pressed(.UP)        { sel = ifx sel < 0 then 0 else max(sel - 1, 0); moved = true; }
        if key_pressed(.PAGE_DOWN) { sel = min(max(sel, 0) + page, row_count - 1); moved = true; }
        if key_pressed(.PAGE_UP)   { sel = max(sel - page, 0); moved = true; }
        if key_pressed(.HOME) && !ctrl_down() { sel = 0; moved = true; }
        if key_pressed(.END)  && !ctrl_down() { sel = row_count - 1; moved = true; }
        if moved {
            for k: Key.[.DOWN, .UP, .PAGE_DOWN, .PAGE_UP, .HOME, .END] input.key_pressed[k] = false;
            if sel != state.selected {
                state.selected = sel;
                t.selection_changed = true;
            }
            ui_scroll_to(*state.scroll, sel * t.row_h, t.row_h, t.body.h);
        }
        if key_pressed(.ENTER) && state.selected >= 0 {
            input.key_pressed[Key.ENTER] = false;
            t.activated = state.selected;
        }
    }
    if state.selected >= row_count { state.selected = row_count - 1; t.selection_changed = true; }

    t.offset = ui_scroll_area(ui_id_combine(t.id, 0x5C), t.body, *state.scroll, row_count * t.row_h);
    t.first = max(cast(int) (t.offset / t.row_h), 0);
    t.last  = min(row_count - 1, cast(int) ((t.offset + t.body.h) / t.row_h));

    push_clip(t.body);

    // The selection highlight glides between rows (and snaps across long jumps).
    sel := ifx highlight then state.selected else -1;
    if sel >= 0 {
        if abs(state.sel_spring.value - sel) > 12 || state.sel_alpha < 0.01 { state.sel_spring.value = xx sel; state.sel_spring.velocity = 0; }
        ui_spring(*state.sel_spring, xx sel, 900, 0.9);
    }
    ui_animate(*state.sel_alpha, ifx sel >= 0 then 1.0 else 0.0, 24);
    if state.sel_alpha > 0.01 {
        y := t.body.y + state.sel_spring.value * t.row_h - t.offset;
        bar := snap(rect(t.body.x, y, t.body.w, t.row_h));
        draw_rect(bar, color_with_alpha(theme.accent_wash, state.sel_alpha));
        draw_rect(snap(rect(bar.x, bar.y, px(2), bar.h)), color_with_alpha(theme.accent, state.sel_alpha));
    }
}

// The rect of row i; handles its hover and clicks.
table_row :: (t: *Data_Table, i: int) -> Rect {
    row := rect(t.body.x, t.body.y + i * t.row_h - t.offset, t.body.w - px(10), t.row_h);
    rid := ui_id_combine(t.id, cast(u64) i + 100_000);
    io := ui_interact(rid, rect(row.x, row.y, t.body.w, row.h));
    if io.hovered {
        t.hovered_row = i;
        if t.state.selected != i || !t.highlight draw_rect(snap(rect(row.x, row.y, t.body.w, row.h)), color_with_alpha(theme.hover, 0.55));
    }
    if io.pressed {
        if t.state.selected != i { t.state.selected = i; t.selection_changed = true; }
        t.clicked = i;
        if io.double_clicked t.activated = i;
        ui_take_focus(t.id);
    }
    ui_divider(row.x, row.y + row.h - hairline(), t.body.w, theme.divider);
    return row;
}

// The padded content rect of column `col` in `row` (zero width if hidden).
table_cell :: (t: *Data_Table, row: Rect, col: int) -> Rect {
    if col >= MAX_COLUMNS || !t.shown[col] return .{};
    return rect(t.x[col] + px(CELL_PAD), row.y, max(t.w[col] - px(2 * CELL_PAD), 0.0), row.h);
}

table_column_shown :: (t: *Data_Table, col: int) -> bool { return col < MAX_COLUMNS && t.shown[col]; }

table_end :: (t: *Data_Table) {
    pop_clip();
    ui_scroll_draw(*t.state.scroll);
}

// Skeleton rows while the first data loads.
table_skeleton :: (t: *Data_Table, rows: int) {
    push_clip(t.body);
    for i: 0..rows - 1 {
        row := rect(t.body.x, t.body.y + i * t.row_h, t.body.w, t.row_h);
        if row.y > t.body.y + t.body.h break;
        for c, ci: t.cols {
            if ci >= MAX_COLUMNS || !t.shown[ci] continue;
            cell := table_cell(t, row, ci);
            w := cell.w * (0.35 + 0.4 * fmod_cycling(cast(float) (i * 0.37 + ci * 0.21), 1.0));
            x := ifx c.align == .RIGHT then cell.x + cell.w - w else cell.x;
            draw_skeleton(rect(x, cell.y + (cell.h - px(8)) * 0.5, w, px(8)), i * 0.07);
        }
        ui_divider(row.x, row.y + row.h - hairline(), t.body.w, theme.divider);
    }
    pop_clip();
}

//
// Cells and chips.
//

// Money with its sign: incoming in green with a plus, outgoing as a plain
// figure with a minus.
draw_amount :: (r: Rect, cents: s64, align := Text_Align.RIGHT, size := 0.0, font: *Font = null, muted := false) -> float {
    s := ifx size > 0 then size else px(theme.font_size_body);
    f := ifx font then font else fonts.regular;
    color := ifx cents > 0 then theme.positive else theme.text;
    if muted color = color_lerp(color, theme.panel, 0.35);
    return draw_text_in_rect(f, s, r, format_money(cents, .ALWAYS), color, align, .{tabular = true});
}

// A small status label: tinted fill, colored text.
draw_chip :: (x: float, cy: float, text: string, color: Color, icon := Icon.NONE) -> float {
    size := px(theme.font_size_small);
    tw := measure_text(fonts.semibold, size, text);
    iw := ifx icon != .NONE then px(13) else 0.0;
    r := snap(rect(x, cy - px(9), tw + iw + px(12), px(18)));
    draw_rect_outline(r, color_with_alpha(color, 0.12), color_with_alpha(color, 0.30), hairline(), px(2));
    if icon != .NONE draw_icon(icon, r.x + px(6) + px(4), cy, px(9), color);
    draw_text_in_rect(fonts.semibold, size, rect(r.x + px(6) + iw, r.y, tw + px(2), r.h), text, color);
    return r.w;
}

draw_status :: (r: Rect, status: Txn_Status) {
    if status == .HELD draw_chip(r.x, r.y + r.h * 0.5, "Held", theme.held, .CLOCK);
    else draw_text_in_rect(fonts.regular, px(theme.font_size_label), r, "Settled", theme.text_muted);
}

// A category swatch and name; "Uncategorised" when it could have one.
draw_category :: (r: Rect, category: s32, categorizable: bool, size := 0.0) {
    s := ifx size > 0 then size else px(theme.font_size_label);
    box := snap(rect(r.x, r.y + (r.h - px(8)) * 0.5, px(8), px(8)));
    text_r := rect(r.x + px(14), r.y, r.w - px(14), r.h);
    if category >= 0 {
        draw_rect(box, category_color(category), px(2));
        draw_text_fit(fonts.regular, s, text_r, store.categories[category].name, theme.text_secondary);
    } else if categorizable {
        draw_rect_outline(box, 0, theme.text_faint, hairline(), px(2));
        draw_text_fit(fonts.regular, s, text_r, "Uncategorised", theme.text_muted);
    } else {
        draw_text_in_rect(fonts.regular, s, r, "—", theme.text_faint);
    }
}

// A thin horizontal share bar (0..1) in a cell.
draw_share_bar :: (r: Rect, fraction: float, color: Color) {
    h := px(4);
    track := snap(rect(r.x, r.y + (r.h - h) * 0.5, r.w, h));
    draw_rect(track, theme.raised, px(1));
    if fraction > 0 {
        fill := track;
        fill.w = max(track.w * clamp(fraction, 0, 1), px(2));
        draw_rect(snap(fill), color, px(1));
    }
}

// Label: value rows for detail views.
draw_field :: (r: Rect, label: string, value: string, mono := false, value_color: Color = 0) {
    label_w := px(112);
    draw_text_in_rect(fonts.regular, px(theme.font_size_label), rect(r.x, r.y, label_w, r.h), label, theme.text_muted);
    font := ifx mono then fonts.mono else fonts.regular;
    size := ifx mono then px(theme.font_size_label) else px(theme.font_size_body);
    draw_text_fit(font, size, rect(r.x + label_w, r.y, r.w - label_w, r.h), value, ifx value_color then value_color else theme.text);
}

// Toolbar strip under the tab bar: a quiet band that holds a page's controls.
TOOLBAR_HEIGHT :: 52.0;

toolbar_rect :: (r: *Rect) -> Rect {
    bar := cut_top(r, px(TOOLBAR_HEIGHT));
    return rect_inset_xy(bar, 0, px(10));   // Controls 32 tall, 10 above and below.
}

