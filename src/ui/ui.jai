// Immediate-mode UI with retained animation state.
//
// Widgets are procedures called every frame with their rectangle; they draw
// themselves and report interaction (clicked, changed). There is no widget
// tree to keep in sync with the app's data. What has to survive between
// frames - hover/press/focus animations, a popup's open state, the text
// being edited - lives in small tables keyed by the widget's id and is
// dropped once a widget stops being drawn.
//
// Keyboard: Tab and Shift+Tab walk the focusable widgets in the order they
// were drawn last frame; the focused one shows a ring (only when focus came
// from the keyboard) and takes Enter/Space and arrow keys.
//
// Layers: popups, menus, tooltips and dialogs draw on the overlay layer and
// block the input of whatever lies beneath them.
//
// Animations are time-based and report `ui.animating` while they move, so
// the main loop renders exactly as long as something is in motion; widgets
// that need a frame later (a caret blink, a tooltip delay) ask for one with
// ui_wake_at, and the loop sleeps until then.

UI_Id :: u64;

UI_Widget :: struct {
    hover:  float;   // 0..1
    press:  float;   // 0..1
    focus:  float;   // Focus ring, 0..1
    t:      float;   // Widget-specific animation.
    spring: Spring;  // Widget-specific motion (toggle knob, segment thumb...).
    spring2: Spring;
    last_frame: u64;
}

Text_Buffer :: struct {
    data:  [512] u8;
    count: s32;
}

buffer_string :: (b: *Text_Buffer) -> string { return string.{b.count, b.data.data}; }
buffer_set :: (b: *Text_Buffer, s: string) {
    n := min(s.count, b.data.count);
    memcpy(b.data.data, s.data, n);
    b.count = cast(s32) n;
}

Scroll :: struct {
    pos:    float;   // Pixels.
    target: float;
    content: float;  // Content height last frame, pixels.
    view:    float;
    dragging: bool;
    drag_mouse: float;
    drag_pos:   float;
    bar_hover:  float;
    thumb:      Rect;    // Where the thumb goes this frame (zero: none).
}

UI_State :: struct {
    scale: float = 1;     // Pixels per logical unit.
    dt:    float;
    time:  float64;
    frame: u64;

    hot:    UI_Id;        // Under the mouse this frame.
    active: UI_Id;        // Being pressed or dragged.

    focus: UI_Id;         // Keyboard focus.
    focus_visible: bool;  // Focus arrived by keyboard: show the ring.
    focus_claimed: bool;  // A widget took focus with the mouse this frame.
    focus_order:      [..] UI_Id;
    focus_order_prev: [..] UI_Id;

    // The focused text field.
    text_focus:      bool;   // A text field has focus (this frame).
    text_focus_prev: bool;
    edit_cursor:  s32;
    edit_anchor:  s32;
    edit_scroll:  float;
    edit_blink:   float64;   // Caret is solid for a moment after input.
    edit_dragging: bool;

    // One popup at a time.
    popup:        UI_Id;
    popup_anchor: Rect;
    popup_rect:   Rect;      // Where it was drawn this frame.
    block_rect:   Rect;      // Where it was drawn last frame: input beneath is blocked.
    popup_t:      float;
    popup_opened: u64;       // Frame it opened.
    popup_drawn:  bool;
    popup_highlight: int = -1;
    popup_scroll: Scroll;
    in_overlay:   bool;
    saved_layer:  Draw_Layer;

    modal:      bool;        // A dialog is up this frame.
    modal_prev: bool;

    tooltip_id:    UI_Id;
    tooltip_since: float64;

    wake_at: float64;        // Earliest time something wants a frame (0 = none).

    mouse_moved: bool;       // Since last frame.
    last_mouse_x, last_mouse_y: float;

    // Clicks: count is 2 for a double click.
    click_count: int;
    last_click_time: float64;
    last_click_x, last_click_y: float;

    animating: bool;      // Something is still moving: render another frame.
    cursor: Cursor;
    motion: float = 1;    // Animation speed (0 = reduced motion: everything snaps).

    widgets: Table(UI_Id, UI_Widget);
    rolls:   Table(UI_Id, Roll_State);
}

ui: UI_State;

px :: inline (logical: float) -> float { return logical * ui.scale; }

// One logical pixel, but never thinner than one physical pixel.
hairline :: inline () -> float { return max(1.0, floor(ui.scale)); }

// Rounds a rectangle's edges to whole pixels, so 1 px borders stay sharp.
snap :: inline (r: Rect) -> Rect {
    x0 := floor(r.x + 0.5);
    y0 := floor(r.y + 0.5);
    x1 := floor(r.x + r.w + 0.5);
    y1 := floor(r.y + r.h + 0.5);
    return rect(x0, y0, x1 - x0, y1 - y0);
}

ui_begin_frame :: (dt: float, time: float64) {
    ui.dt    = dt;
    ui.time  = time;
    ui.scale = platform.dpi_scale;
    ui.frame += 1;
    ui.hot = 0;
    ui.animating = false;
    ui.cursor = .ARROW;
    ui.wake_at = 0;
    ui.focus_claimed = false;
    ui.text_focus_prev = ui.text_focus;
    ui.text_focus = false;
    ui.modal_prev = ui.modal;
    ui.modal = false;

    ui.block_rect = ifx ui.popup then ui.popup_rect else .{};
    ui.mouse_moved = input.mouse_x != ui.last_mouse_x || input.mouse_y != ui.last_mouse_y;
    ui.last_mouse_x, ui.last_mouse_y = input.mouse_x, input.mouse_y;
    ui.popup_drawn = false;

    // Double clicks.
    if input.mouse_pressed[Mouse_Button.LEFT] {
        near := abs(input.mouse_x - ui.last_click_x) < px(4) && abs(input.mouse_y - ui.last_click_y) < px(4);
        if near && ui.time - ui.last_click_time < platform.double_click_seconds ui.click_count += 1;
        else ui.click_count = 1;
        ui.last_click_time = ui.time;
        ui.last_click_x, ui.last_click_y = input.mouse_x, input.mouse_y;
    }

    // A press outside the open popup closes it and goes no further (unless
    // it is on the popup's own anchor, which toggles it).
    if ui.popup && input.mouse_pressed[Mouse_Button.LEFT] {
        mx, my := input.mouse_x, input.mouse_y;
        if !rect_contains(ui.popup_rect, mx, my) {
            on_anchor := rect_contains(ui.popup_anchor, mx, my);
            ui_close_popup();
            if !on_anchor input.mouse_pressed[Mouse_Button.LEFT] = false;
            else ui.popup_opened = ui.frame;   // So the anchor doesn't reopen it this frame.
        }
    }

    // Tab walks focus through last frame's focusable widgets.
    array_reset_keeping_memory(*ui.focus_order_prev);
    for ui.focus_order array_add(*ui.focus_order_prev, it);
    array_reset_keeping_memory(*ui.focus_order);
    if key_pressed(.TAB) && !ui.popup {
        list := ui.focus_order_prev;
        if list.count {
            index := -1;
            for list if it == ui.focus { index = it_index; break; }
            if shift_down() index = ifx index <= 0 then list.count - 1 else index - 1;
            else index = (index + 1) % list.count;
            ui.focus = list[index];
            ui.focus_visible = true;
        }
        input.key_pressed[Key.TAB] = false;
    }
    if ui.popup ui.animating = ui.animating || ui.popup_t < 1;
}

ui_end_frame :: () {
    if !input.mouse_down[Mouse_Button.LEFT] ui.active = 0;   // Its widget went away mid-press.
    // A click on nothing focusable drops focus.
    if input.mouse_pressed[Mouse_Button.LEFT] && !ui.focus_claimed ui.focus = 0;
    // A popup whose owner wasn't drawn this frame (page changed) closes.
    if ui.popup && !ui.popup_drawn ui_close_popup();
    platform_set_cursor(ui.cursor);

    // Forget widgets that were not drawn for a while.
    if ui.frame % 256 == 0 {
        stale: [..] UI_Id;
        stale.allocator = temp;
        for ui.widgets if ui.frame - it.last_frame > 256 array_add(*stale, it_index);
        for stale table_remove(*ui.widgets, it);
    }
}

// Asks for a frame at `time` (ui clock), even if nothing else happens.
ui_wake_at :: (time: float64) {
    if time <= ui.time { ui.animating = true; return; }
    if ui.wake_at == 0 || time < ui.wake_at ui.wake_at = time;
}

// FNV-1a. Text after "##" is part of the id but not displayed, so two
// buttons can share a label.
ui_id :: (text: string, index := 0) -> UI_Id {
    h: u64 = 0xcbf29ce484222325;
    for 0..text.count - 1 {
        h ^= text[it];
        h *= 0x100000001b3;
    }
    h ^= (cast(u64) index) * 0x9E3779B97F4A7C15;
    return h;
}

ui_id_combine :: (a: UI_Id, b: UI_Id) -> UI_Id {
    return (a ^ (b + 0x9E3779B97F4A7C15 + (a << 6) + (a >> 2))) * 0x100000001b3;
}

display_text :: (text: string) -> string {
    found, before := split_from_left(text, "##");
    return ifx found then before else text;
}

// The widget's retained state; `is_new` on the first frame it is drawn.
ui_widget :: (id: UI_Id) -> *UI_Widget, is_new: bool {
    w := table_find_pointer(*ui.widgets, id);
    is_new := !w;
    if is_new w = table_add(*ui.widgets, id, .{});
    w.last_frame = ui.frame;
    return w, is_new;
}

// Moves value toward target at `speed` (1/seconds), flagging the frame as
// animating until it arrives.
ui_animate :: (value: *float, target: float, speed: float) {
    if value.* == target return;
    if ui.motion <= 0 { value.* = target; return; }
    value.* = damp(value.*, target, speed * ui.motion, ui.dt);
    // Close enough relative to the size of the value: big values (cents)
    // can't get within a fixed epsilon in single precision.
    if abs(value.* - target) < max(0.002, abs(target) * 0.0005) value.* = target;
    else ui.animating = true;
}

ui_spring :: (s: *Spring, target: float, stiffness := 300.0, damping_ratio := 0.75) -> float {
    s.target = target;
    if ui.motion <= 0 { s.value = target; s.velocity = 0; return target; }
    if spring_update(s, ui.dt * ui.motion, stiffness, damping_ratio) ui.animating = true;
    return s.value;
}

// The mouse is over r, nothing above it blocks it, and it is inside the clip.
ui_mouse_in :: (r: Rect) -> bool {
    mx, my := input.mouse_x, input.mouse_y;
    if !input.mouse_inside || !rect_contains(r, mx, my) return false;
    clip := draw.clip;
    if mx < clip[0] || my < clip[1] || mx >= clip[2] || my >= clip[3] return false;
    if !ui.in_overlay {
        if ui.modal_prev return false;
        if ui.block_rect.w > 0 && rect_contains(ui.block_rect, mx, my) return false;
    }
    return true;
}

Interaction :: struct {
    hovered: bool;   // Under the mouse (and nothing else is being pressed).
    pressed: bool;   // Mouse went down on it this frame.
    held:    bool;   // Mouse is down and it was pressed on it.
    clicked: bool;   // Released while over it, after being pressed on it.
    double_clicked: bool;
    right_clicked: bool;
}

ui_interact :: (id: UI_Id, r: Rect) -> Interaction {
    result: Interaction;
    over := ui_mouse_in(r);
    result.hovered = over && (ui.active == 0 || ui.active == id);
    if result.hovered ui.hot = id;
    if result.hovered && input.mouse_pressed[Mouse_Button.LEFT] {
        ui.active = id;
        result.pressed = true;
        result.double_clicked = ui.click_count >= 2;
    }
    if result.hovered && input.mouse_pressed[Mouse_Button.RIGHT] result.right_clicked = true;
    if ui.active == id {
        if input.mouse_released[Mouse_Button.LEFT] {
            result.clicked = over;
            ui.active = 0;
        } else {
            result.held = input.mouse_down[Mouse_Button.LEFT];
        }
    }
    return result;
}

// Registers id in the Tab order; true if it has keyboard focus.
ui_focusable :: (id: UI_Id) -> bool {
    array_add(*ui.focus_order, id);
    return ui.focus == id;
}

ui_take_focus :: (id: UI_Id, visible := false) {
    ui.focus = id;
    ui.focus_visible = visible;
    ui.focus_claimed = true;
}

// The focused widget was activated from the keyboard (Enter or Space).
ui_key_activate :: (id: UI_Id) -> bool {
    if ui.focus != id || ui.text_focus_prev return false;
    if key_pressed(.ENTER) { input.key_pressed[Key.ENTER] = false; return true; }
    if key_pressed(.SPACE) { input.key_pressed[Key.SPACE] = false; return true; }
    return false;
}

// A 2 px ring outside r, faded by t.
ui_focus_ring :: (r: Rect, t: float, radius: float) {
    if t <= 0.01 return;
    g := px(2) * t + px(1);
    ring := snap(rect(r.x - g, r.y - g, r.w + 2 * g, r.h + 2 * g));
    draw_rect_outline(ring, 0, color_with_alpha(theme.accent, t), px(1.5), radius + g);
}

// Animates w.focus toward whether the ring should show.
ui_update_focus :: (w: *UI_Widget, id: UI_Id) {
    ui_animate(*w.focus, ifx ui.focus == id && ui.focus_visible then 1.0 else 0.0, 24);
}

//
// Text helpers.
//

Label_Style :: enum u8 { BODY; SECONDARY; MUTED; CAPS; }

// Small caps section label: "ACCOUNTS".
CAPS_STYLE :: Text_Style.{tracking = 0.7};

caps_tracking :: () -> Text_Style { return .{tracking = px(0.6)}; }

draw_caps :: (r: Rect, text: string, color: Color, align := Text_Align.LEFT) -> float {
    return draw_text_in_rect(fonts.semibold, px(theme.font_size_small), r, to_upper_temp(text), color, align, caps_tracking());
}

measure_caps :: (text: string) -> float {
    return measure_text(fonts.semibold, px(theme.font_size_small), to_upper_temp(text), caps_tracking());
}

to_upper_temp :: (s: string) -> string {
    result := copy_string(s,, temp);
    for 0..result.count - 1 {
        c := result[it];
        if c >= #char "a" && c <= #char "z" result[it] = c - 32;
    }
    return result;
}

draw_icon :: (icon: Icon, cx: float, cy: float, size: float, color: Color) {
    if icon == .NONE return;
    draw_glyph_centered(fonts.icons, size, cx, cy, cast(u32) icon, color);
}

draw_icon_in :: (icon: Icon, r: Rect, size: float, color: Color) {
    draw_icon(icon, r.x + r.w * 0.5, r.y + r.h * 0.5, size, color);
}

//
// Panels.
//

ui_panel :: (area: Rect, fill_color: Color = 0) {
    fill := ifx fill_color then fill_color else theme.panel;
    draw_rect_outline(snap(area), fill, theme.border, hairline(), px(theme.radius_panel));
}

// Thin horizontal line.
ui_divider :: (x: float, y: float, w: float, color: Color = 0) {
    draw_rect(snap(rect(x, y, w, hairline())), ifx color then color else theme.divider);
}

ui_vdivider :: (x: float, y: float, h: float, color: Color = 0) {
    draw_rect(snap(rect(x, y, hairline(), h)), ifx color then color else theme.divider);
}

//
// Buttons.
//

Button_Style :: enum u8 { PRIMARY; SECONDARY; GHOST; DANGER; }

ui_button_width :: (label: string, icon := Icon.NONE) -> float {
    w := measure_text(fonts.semibold, px(theme.font_size_label), display_text(label)) + px(24);
    if icon != .NONE w += px(20);
    return max(w, px(28));
}

ui_button :: (label: string, r: Rect, style := Button_Style.SECONDARY, icon := Icon.NONE, enabled := true, tooltip := "") -> bool {
    id := ui_id(label);
    w := ui_widget(id);
    io: Interaction;
    if enabled io = ui_interact(id, r);
    focused := enabled && ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    ui_animate(*w.hover, ifx io.hovered || io.held then 1.0 else 0.0, 22);
    ui_animate(*w.press, ifx io.held && io.hovered then 1.0 else 0.0, 30);
    if io.hovered ui.cursor = .HAND;
    activated := io.clicked || (enabled && ui_key_activate(id));
    if tooltip.count ui_tooltip(id, io.hovered, tooltip);

    b := snap(r);
    radius := px(theme.radius_control);
    text_color: Color;
    if style == {
        case .PRIMARY;
            fill := color_lerp(color_lerp(theme.accent, theme.accent_hover, w.hover), theme.accent_pressed, w.press);
            if !enabled fill = theme.raised;
            draw_rect(b, fill, radius);
            text_color = ifx enabled then theme.on_accent else theme.text_faint;
        case .SECONDARY;
            fill := color_lerp(color_lerp(theme.raised, theme.hover, w.hover), theme.active, w.press);
            draw_rect_outline(b, fill, color_lerp(theme.border, theme.border_strong, w.hover), hairline(), radius);
            text_color = ifx enabled then theme.text else theme.text_faint;
        case .GHOST;
            draw_rect(b, color_with_alpha(theme.hover, w.hover * (1 - 0.3 * w.press)), radius);
            text_color = ifx enabled then color_lerp(theme.text_secondary, theme.text, w.hover) else theme.text_faint;
        case .DANGER;
            draw_rect_outline(b, color_with_alpha(theme.danger, 0.10 * w.hover + 0.06 * w.press), color_with_alpha(theme.danger, 0.35 + 0.4 * w.hover), hairline(), radius);
            text_color = ifx enabled then color_lerp(theme.danger, rgb(0xFFB3B7), w.hover * 0.5) else theme.text_faint;
    }
    ui_focus_ring(b, w.focus, radius);

    text := display_text(label);
    size := px(theme.font_size_label);
    if icon != .NONE {
        tw := ifx text.count then measure_text(fonts.semibold, size, text) else 0.0;
        total := px(14) + ifx text.count then px(6) + tw else 0.0;
        x := b.x + (b.w - total) * 0.5;
        draw_icon(icon, x + px(7), b.y + b.h * 0.5, px(12), text_color);
        if text.count draw_text_in_rect(fonts.semibold, size, rect(x + px(20), b.y, tw + px(2), b.h), text, text_color);
    } else {
        draw_text_in_rect(fonts.semibold, size, b, text, text_color, .CENTER);
    }
    return activated && enabled;
}

// A square button holding an icon, with a tooltip.
ui_icon_button :: (label: string, icon: Icon, r: Rect, tooltip := "", active := false, enabled := true, color: Color = 0) -> bool {
    id := ui_id(label);
    w := ui_widget(id);
    io: Interaction;
    if enabled io = ui_interact(id, r);
    ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    ui_animate(*w.hover, ifx io.hovered || io.held then 1.0 else 0.0, 22);
    ui_animate(*w.press, ifx active then 1.0 else 0.0, 18);
    if io.hovered ui.cursor = .HAND;
    if tooltip.count ui_tooltip(id, io.hovered, tooltip);
    b := snap(r);
    radius := px(theme.radius_control);
    draw_rect(b, color_with_alpha(theme.hover, max(w.hover, w.press * 0.8)), radius);
    base := ifx color then color else theme.text_secondary;
    c := ifx enabled then color_lerp(base, theme.text, max(w.hover, w.press)) else theme.text_faint;
    draw_icon_in(icon, b, px(13), c);
    ui_focus_ring(b, w.focus, radius);
    return enabled && (io.clicked || ui_key_activate(id));
}

// A link-styled inline text button.
ui_link :: (label: string, r: Rect, color: Color = 0) -> bool {
    id := ui_id(label);
    w := ui_widget(id);
    io := ui_interact(id, r);
    ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 22);
    if io.hovered ui.cursor = .HAND;
    base := ifx color then color else theme.accent;
    c := color_lerp(base, theme.accent_hover, w.hover);
    tw := draw_text_in_rect(fonts.regular, px(theme.font_size_label), r, display_text(label), c);
    baseline := text_baseline_in(fonts.regular, px(theme.font_size_label), r);
    draw_rect(snap(rect(r.x, baseline + px(2), tw, hairline())), color_with_alpha(c, 0.35 + 0.65 * w.hover));
    ui_focus_ring(rect(r.x - px(2), r.y, tw + px(4), r.h), w.focus, px(2));
    return io.clicked || ui_key_activate(id);
}

//
// Toggles, checkboxes, sliders.
//

// A labeled switch filling the row r. Returns true when toggled.
ui_toggle :: (label: string, r: Rect, value: *bool, detail := "") -> bool {
    id := ui_id(label);
    w, is_new := ui_widget(id);
    if is_new w.spring.value = ifx value.* then 1.0 else 0.0;   // Appear in place.
    io := ui_interact(id, r);
    ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    toggled := io.clicked || ui_key_activate(id);
    if toggled value.* = !value.*;
    if io.hovered ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 20);
    t := ui_spring(*w.spring, ifx value.* then 1.0 else 0.0, 520, 0.72);

    text_r := r;
    text_r.w -= px(48);
    if detail.count {
        top := cut_top(*text_r, text_r.h * 0.5);
        draw_text_in_rect(fonts.regular, px(theme.font_size_body), rect(top.x, top.y + px(3), top.w, top.h), display_text(label), theme.text);
        draw_text_fit(fonts.regular, px(theme.font_size_label), rect(text_r.x, text_r.y - px(2), text_r.w, text_r.h), detail, theme.text_muted);
    } else {
        draw_text_in_rect(fonts.regular, px(theme.font_size_body), text_r, display_text(label), theme.text);
    }

    track_w := px(30);
    track_h := px(16);
    track := snap(rect(r.x + r.w - track_w, r.y + (r.h - track_h) * 0.5, track_w, track_h));
    off_color := color_lerp(theme.raised, theme.hover, w.hover);
    on_color  := color_lerp(theme.accent, theme.accent_hover, w.hover);
    fill := color_lerp(off_color, on_color, clamp(t, 0, 1));
    draw_rect_outline(track, fill, color_lerp(theme.border_strong, on_color, clamp(t, 0, 1)), hairline(), track.h * 0.5);
    knob_r := px(5.5);
    inset  := (track.h - 2 * knob_r) * 0.5;
    cx := track.x + inset + knob_r + (track.w - 2 * inset - 2 * knob_r) * t;
    cy := track.y + track.h * 0.5;
    draw_circle(cx, cy, knob_r, color_lerp(theme.text_secondary, theme.on_accent, clamp(t, 0, 1)));
    ui_focus_ring(track, w.focus, track.h * 0.5);
    return toggled;
}

ui_checkbox :: (label: string, r: Rect, value: *bool) -> bool {
    id := ui_id(label);
    w, is_new := ui_widget(id);
    if is_new w.t = ifx value.* then 1.0 else 0.0;
    io := ui_interact(id, r);
    ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    toggled := io.clicked || ui_key_activate(id);
    if toggled value.* = !value.*;
    if io.hovered ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 20);
    ui_animate(*w.t, ifx value.* then 1.0 else 0.0, 26);

    box := snap(rect(r.x, r.y + (r.h - px(14)) * 0.5, px(14), px(14)));
    fill := color_lerp(color_lerp(theme.raised, theme.hover, w.hover), theme.accent, w.t);
    draw_rect_outline(box, fill, color_lerp(theme.border_strong, theme.accent, w.t), hairline(), px(2));
    if w.t > 0.01 {
        push_opacity(w.t);
        draw_icon_in(.CHECK, box, px(10), theme.on_accent);
        pop_opacity();
    }
    ui_focus_ring(box, w.focus, px(2));
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), rect(box.x + px(22), r.y, r.w - px(22), r.h), display_text(label), theme.text);
    return toggled;
}

// A labeled horizontal slider filling the row r (label above, track below).
ui_slider :: (label: string, r: Rect, value: *float, lo: float, hi: float, value_text: string) -> bool {
    id := ui_id(label);
    w := ui_widget(id);

    label_row := r;
    top := cut_top(*label_row, r.h * 0.5);
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), top, display_text(label), theme.text, .LEFT);
    draw_text_in_rect(fonts.mono, px(theme.font_size_label), top, value_text, theme.text_secondary, .RIGHT);

    track_area := label_row;
    io := ui_interact(id, track_area);
    ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    if io.hovered || io.held ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered || io.held then 1.0 else 0.0, 20);
    ui_animate(*w.press, ifx io.held then 1.0 else 0.0, 24);

    knob_r := px(6);
    track := snap(rect(track_area.x + knob_r, track_area.y + track_area.h * 0.5 - px(1.5), track_area.w - 2 * knob_r, px(3)));

    changed := false;
    if io.held {
        t := clamp((input.mouse_x - track.x) / max(track.w, 1.0), 0, 1);
        new_value := lo + (hi - lo) * t;
        if new_value != value.* { value.* = new_value; changed = true; }
    }
    if ui.focus == id && !ui.text_focus_prev {
        step := (hi - lo) / 20;
        if key_pressed(.LEFT)  { value.* = clamp(value.* - step, lo, hi); changed = true; }
        if key_pressed(.RIGHT) { value.* = clamp(value.* + step, lo, hi); changed = true; }
    }

    t := clamp((value.* - lo) / (hi - lo), 0, 1);
    fill := track;
    fill.w = track.w * t;
    draw_rect(track, theme.raised, track.h * 0.5);
    draw_rect(fill, theme.accent, track.h * 0.5);

    cx := track.x + track.w * t;
    cy := track.y + track.h * 0.5;
    radius := knob_r * (1 + 0.15 * w.hover + 0.1 * w.press);
    halo := radius + px(5) * w.hover;
    if w.hover > 0 draw_circle(cx, cy, halo, color_with_alpha(theme.accent_soft, w.hover));
    draw_circle(cx, cy, radius, theme.text);
    ui_focus_ring(rect(cx - radius, cy - radius, 2 * radius, 2 * radius), w.focus, radius);
    return changed;
}

//
// Segmented control: a few mutually exclusive options in one strip. The
// highlight glides between segments.
//

ui_segmented_width :: (options: [] string) -> float {
    w := px(2);
    for options w += measure_text(fonts.semibold, px(theme.font_size_label), it) + px(20);
    return w;
}

ui_segmented :: (label: string, r_in: Rect, options: [] string, selected: *int) -> bool {
    id := ui_id(label);
    w, is_new := ui_widget(id);
    if is_new w.spring.value = xx selected.*;
    r := snap(r_in);
    focused := ui_focusable(id);
    ui_update_focus(w, id);
    changed := false;
    if focused && !ui.text_focus_prev {
        if key_pressed(.LEFT) && selected.* > 0 { selected.* -= 1; changed = true; }
        if key_pressed(.RIGHT) && selected.* < options.count - 1 { selected.* += 1; changed = true; }
    }

    // Segment widths in proportion to their labels, filling r.
    widths: [16] float;
    natural: float;
    n := min(options.count, widths.count);
    for 0..n - 1 {
        widths[it] = measure_text(fonts.semibold, px(theme.font_size_label), options[it]) + px(20);
        natural += widths[it];
    }
    inner := rect_inset(r, px(1));
    scale := inner.w / max(natural, 1.0);
    for 0..n - 1 widths[it] *= scale;

    radius := px(theme.radius_control);
    draw_rect_outline(r, theme.chrome, theme.border, hairline(), radius);

    pos := ui_spring(*w.spring, xx selected.*, 600, 0.82);
    // Thumb: interpolate between the neighbouring segments' rects.
    i0 := clamp(cast(int) floor(pos), 0, n - 1);
    i1 := min(i0 + 1, n - 1);
    f := clamp(pos - i0, 0, 1);
    x0, x1: float = inner.x, inner.x;
    for 0..i0 - 1 x0 += widths[it];
    for 0..i1 - 1 x1 += widths[it];
    thumb := rect(lerp(x0, x1, f), inner.y, lerp(widths[i0], widths[i1], f), inner.h);
    draw_rect_outline(snap(thumb), theme.active, theme.border_strong, hairline(), radius - px(1));

    x := inner.x;
    for 0..n - 1 {
        seg := rect(x, inner.y, widths[it], inner.h);
        x += widths[it];
        sid := ui_id_combine(id, cast(u64) it + 1);
        sw := ui_widget(sid);
        io := ui_interact(sid, seg);
        if io.hovered ui.cursor = .HAND;
        ui_animate(*sw.hover, ifx io.hovered then 1.0 else 0.0, 22);
        if io.pressed { ui_take_focus(id); }
        if io.clicked && selected.* != it { selected.* = it; changed = true; }
        is_sel := selected.* == it;
        c := ifx is_sel then theme.text else color_lerp(theme.text_muted, theme.text_secondary, sw.hover);
        draw_text_in_rect(fonts.semibold, px(theme.font_size_label), seg, options[it], c, .CENTER);
    }
    ui_focus_ring(r, w.focus, radius);
    return changed;
}

//
// Popups. One at a time; drawn on the overlay layer, they block input to
// whatever is beneath and close on Escape or a click elsewhere.
//

ui_open_popup :: (id: UI_Id, anchor: Rect) {
    ui.popup = id;
    ui.popup_anchor = anchor;
    ui.popup_t = 0;
    ui.popup_opened = ui.frame;
    ui.popup_highlight = -1;
    ui.popup_scroll = .{};
    ui.animating = true;
}

ui_close_popup :: () {
    ui.popup = 0;
    ui.popup_rect = .{};
    ui.block_rect = .{};
}

ui_popup_is_open :: (id: UI_Id) -> bool { return ui.popup == id; }

// Starts drawing the popup `id` if it is open: below its anchor (above when
// there is no room), `width` x `height` pixels. Pair with ui_popup_end.
ui_popup_begin :: (id: UI_Id, width: float, height: float, align_right := false) -> bool, Rect {
    if ui.popup != id return false, .{};
    a := ui.popup_anchor;
    gap := px(4);
    x := ifx align_right then a.x + a.w - width else a.x;
    x = clamp(x, px(8), draw.width - width - px(8));
    y := a.y + a.h + gap;
    if y + height > draw.height - px(8) && a.y - gap - height > px(8) y = a.y - gap - height;
    h := min(height, draw.height - y - px(8));
    r := snap(rect(x, y, width, h));
    ui.popup_rect = r;
    ui.popup_drawn = true;
    ui_animate(*ui.popup_t, 1, 26);

    if key_pressed(.ESCAPE) {
        input.key_pressed[Key.ESCAPE] = false;
        ui_close_popup();
        ui.popup_drawn = true;   // Closed on purpose; don't report it as orphaned.
    }

    ui.saved_layer = draw_set_layer(.OVERLAY);
    push_clip_absolute(rect(0, 0, draw.width, draw.height));
    ui.in_overlay = true;

    t := ease_out_cubic(ui.popup_t);
    shown := r;
    shown.h = r.h * (0.85 + 0.15 * t);
    push_opacity(t);
    draw_shadow(shown, px(theme.radius_panel), px(18), theme.shadow, 0, px(6));
    draw_rect_outline(shown, theme.panel_header, theme.border_strong, hairline(), px(theme.radius_panel));
    push_clip(shown);
    return true, r;
}

ui_popup_end :: () {
    pop_clip();
    pop_opacity();
    ui.in_overlay = false;
    pop_clip();
    draw_set_layer(ui.saved_layer);
}

//
// Dropdown: a button showing the current choice; the list opens below it.
//

Dropdown_Item :: struct {
    label:  string;
    header: bool;      // A non-selectable group heading.
    indent: bool;
    dot:    Color;     // Optional color key (category hue).
    detail: string;    // Right-aligned muted text (a count).
}

ui_dropdown_strings :: (label: string, r: Rect, options: [] string, selected: *int, prefix := "") -> bool {
    items := NewArray(options.count, Dropdown_Item,, temp);
    for options items[it_index].label = it;
    return ui_dropdown(label, r, items, selected, prefix);
}

ui_dropdown :: (label: string, r: Rect, items: [] Dropdown_Item, selected: *int, prefix := "", popup_width := 0.0) -> bool {
    id := ui_id(label);
    w := ui_widget(id);
    io := ui_interact(id, r);
    focused := ui_focusable(id);
    if io.pressed ui_take_focus(id);
    ui_update_focus(w, id);
    open := ui.popup == id;
    if io.hovered ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered || open then 1.0 else 0.0, 22);

    toggle := io.pressed && ui.popup_opened != ui.frame;
    if focused && !open && !ui.text_focus_prev && (key_pressed(.ENTER) || key_pressed(.SPACE) || key_pressed(.DOWN)) {
        toggle = true;
        input.key_pressed[Key.ENTER] = false;
        input.key_pressed[Key.SPACE] = false;
        input.key_pressed[Key.DOWN] = false;
    }
    if toggle {
        if open ui_close_popup();
        else {
            ui_open_popup(id, r);
            ui.popup_highlight = selected.*;
        }
        open = ui.popup == id;
    }

    b := snap(r);
    radius := px(theme.radius_control);
    active := selected.* > 0;
    draw_rect_outline(b, color_lerp(theme.raised, theme.hover, w.hover), ifx open then theme.border_strong else color_lerp(theme.border, theme.border_strong, w.hover), hairline(), radius);
    inner := rect_inset_xy(b, px(10), 0);
    chevron := cut_right(*inner, px(14));
    draw_icon_in(ifx open then Icon.CHEVRON_UP else .CHEVRON_DOWN, chevron, px(9), theme.text_muted);
    size := px(theme.font_size_label);
    value := ifx selected.* >= 0 && selected.* < items.count then items[selected.*].label else "";
    if prefix.count {
        pw := draw_text_in_rect(fonts.regular, size, inner, prefix, theme.text_muted);
        cut_left(*inner, pw + px(5));
    }
    draw_text_fit(fonts.semibold, size, inner, value, ifx active || !prefix.count then theme.text else theme.text_secondary);
    ui_focus_ring(b, w.focus, radius);

    changed := false;
    if open {
        row_h := px(26);
        widest := b.w;
        for items {
            iw := measure_text(fonts.regular, size, it.label) + px(48) + ifx it.detail.count then measure_text(fonts.regular, size, it.detail) + px(16) else 0.0;
            widest = max(widest, iw);
        }
        pw := ifx popup_width > 0 then popup_width else min(widest, px(360));
        list_h := items.count * row_h + px(8);
        visible, area := ui_popup_begin(id, pw, min(list_h, px(420)));
        if visible {
            // Keyboard: arrows move the highlight past headings; Enter picks.
            hl := ui.popup_highlight;
            move :: (hl: int, dir: int, items: [] Dropdown_Item) -> int {
                h := hl;
                for 1..items.count {
                    h += dir;
                    if h < 0 || h >= items.count return hl;
                    if !items[h].header return h;
                }
                return hl;
            }
            if key_pressed(.DOWN) hl = move(hl, 1, items);
            if key_pressed(.UP)   hl = move(hl, -1, items);
            if key_pressed(.ENTER) && hl >= 0 && hl < items.count && !items[hl].header {
                if selected.* != hl { selected.* = hl; changed = true; }
                ui_close_popup();
            }

            content := rect_inset_xy(area, 0, px(4));
            offset := ui_scroll_area(ui_id_combine(id, 77), content, *ui.popup_scroll, items.count * row_h);
            if hl != ui.popup_highlight && hl >= 0 ui_scroll_to(*ui.popup_scroll, hl * row_h, row_h, content.h);
            ui.popup_highlight = hl;

            push_clip(content);
            first := cast(int) (offset / row_h);
            last  := min(items.count - 1, cast(int) ((offset + content.h) / row_h) + 1);
            for i: max(first, 0)..last {
                item := items[i];
                row := rect(content.x, content.y + i * row_h - offset, content.w, row_h);
                if item.header {
                    if i > 0 ui_divider(row.x + px(8), row.y, row.w - px(16), theme.border);
                    t := rect_inset_xy(row, px(12), 0);
                    if item.dot {
                        draw_rect(snap(rect(t.x, t.y + (t.h - px(8)) * 0.5, px(8), px(8))), item.dot, px(2));
                        cut_left(*t, px(14));
                    }
                    draw_caps(t, item.label, theme.text_muted);
                    continue;
                }
                rid := ui_id_combine(id, cast(u64) i + 1000);
                rw := ui_widget(rid);
                rio := ui_interact(rid, row);
                if rio.hovered { ui.cursor = .HAND; if ui.mouse_moved || rio.pressed ui.popup_highlight = i; }
                ui_animate(*rw.hover, ifx ui.popup_highlight == i then 1.0 else 0.0, 30);
                if rw.hover > 0 draw_rect(snap(rect_inset_xy(row, px(4), px(1))), color_with_alpha(theme.hover, rw.hover), px(2));
                t := rect_inset_xy(row, px(12), 0);
                check := cut_left(*t, px(14));
                if i == selected.* draw_icon_in(.CHECK, check, px(10), theme.accent);
                if item.indent cut_left(*t, px(10));
                if item.dot {
                    draw_rect(snap(rect(t.x, t.y + (t.h - px(8)) * 0.5, px(8), px(8))), item.dot, px(2));
                    cut_left(*t, px(14));
                }
                if item.detail.count {
                    dw := draw_text_in_rect(fonts.regular, size, t, item.detail, theme.text_muted, .RIGHT, .{tabular = true});
                    t.w -= dw + px(10);
                }
                draw_text_fit(fonts.regular, size, t, item.label, ifx i == selected.* then theme.text else theme.text_secondary);
                if rio.clicked {
                    if selected.* != i { selected.* = i; changed = true; }
                    ui_close_popup();
                    ui.popup_drawn = true;
                }
            }
            pop_clip();
            ui_scroll_draw(*ui.popup_scroll);
            ui_popup_end();
        }
    }
    return changed;
}

//
// Scrolling.
//

// Handles the wheel over `view` and the scrollbar; returns the offset in
// pixels to subtract from content positions.
ui_scroll_area :: (id: UI_Id, view: Rect, s: *Scroll, content_height: float, step := 0.0) -> float {
    s.content = content_height;
    s.view = view.h;
    max_scroll := max(content_height - view.h, 0.0);
    if ui_mouse_in(view) && input.wheel != 0 {
        st := ifx step > 0 then step else px(theme.row_height) * 3;
        s.target -= input.wheel * st;
        input.wheel = 0;   // Consumed.
    }
    s.target = clamp(s.target, 0, max_scroll);

    // Scrollbar: a thin thumb on the right edge that widens when hovered.
    if max_scroll > 0 {
        zone := rect(view.x + view.w - px(10), view.y, px(10), view.h);
        track := rect_inset_xy(zone, 0, px(3));
        visible := view.h / content_height;
        thumb_h := max(track.h * visible, px(28));
        thumb_y := track.y + (track.h - thumb_h) * (s.pos / max_scroll);
        bar_id := ui_id_combine(id, 0xBA5);
        io := ui_interact(bar_id, zone);
        if io.pressed {
            s.dragging = true;
            s.drag_mouse = input.mouse_y;
            // Clicking the track jumps there; the thumb is grabbed in place.
            if input.mouse_y < thumb_y || input.mouse_y > thumb_y + thumb_h {
                frac := clamp((input.mouse_y - track.y - thumb_h * 0.5) / max(track.h - thumb_h, 1.0), 0, 1);
                s.target = frac * max_scroll;
                s.pos = s.target;
            }
            s.drag_pos = s.target;
        }
        if s.dragging {
            if input.mouse_down[Mouse_Button.LEFT] {
                delta := (input.mouse_y - s.drag_mouse) / max(track.h - thumb_h, 1.0) * max_scroll;
                s.target = clamp(s.drag_pos + delta, 0, max_scroll);
                s.pos = s.target;
            } else {
                s.dragging = false;
            }
        }
        ui_animate(*s.bar_hover, ifx io.hovered || s.dragging then 1.0 else 0.0, 20);
        bw := px(3) + px(3) * s.bar_hover;
        s.thumb = rect(zone.x + zone.w - bw - px(2), thumb_y, bw, thumb_h);
    } else {
        s.dragging = false;
        s.thumb = .{};
    }

    if !s.dragging ui_animate(*s.pos, s.target, 20);
    s.pos = clamp(s.pos, 0, max_scroll);
    return floor(s.pos + 0.5);
}

// Draws the scrollbar thumb; call after the content, so it stays on top.
ui_scroll_draw :: (s: *Scroll) {
    if s.thumb.h <= 0 return;
    draw_rect(s.thumb, color_lerp(theme.border_strong, theme.text_muted, s.bar_hover), s.thumb.w * 0.5);
}

// Scrolls just enough to show [top, top + height] (content pixels).
ui_scroll_to :: (s: *Scroll, top: float, height: float, view_height: float) {
    if top < s.target s.target = top;
    else if top + height > s.target + view_height s.target = top + height - view_height;
    s.target = max(s.target, 0);
}

//
// Tooltips: shown after the mouse rests on a widget for a moment.
//

TOOLTIP_DELAY :: 0.45;

ui_tooltip :: (id: UI_Id, hovered: bool, text: string) {
    if !hovered {
        if ui.tooltip_id == id ui.tooltip_id = 0;
        return;
    }
    if ui.tooltip_id != id {
        ui.tooltip_id = id;
        ui.tooltip_since = ui.time;
    }
    elapsed := ui.time - ui.tooltip_since;
    if elapsed < TOOLTIP_DELAY {
        ui_wake_at(ui.tooltip_since + TOOLTIP_DELAY);
        return;
    }
    t := clamp(cast(float) (elapsed - TOOLTIP_DELAY) / 0.12, 0, 1);
    if t < 1 ui.animating = true;
    draw_tooltip(input.mouse_x, input.mouse_y, text, t);
}

// A tooltip box near (x, y). Lines split on '\n'; a line "label\tvalue"
// is a row with the label on the left and the value right-aligned.
draw_tooltip :: (x: float, y: float, text: string, t := 1.0, min_width := 0.0) {
    size := px(theme.font_size_label);
    lines := split(text, "\n",, temp);
    style := Text_Style.{tabular = true};
    label_w, value_w, plain_w: float;
    for lines {
        found, label, value := split_from_left(it, "\t");
        if found {
            label_w = max(label_w, measure_text(fonts.regular, size, label));
            value_w = max(value_w, measure_text(fonts.regular, size, value, style));
        } else {
            plain_w = max(plain_w, measure_text(fonts.semibold, size, it, style));
        }
    }
    line_h := px(17);
    box_w := max(max(plain_w, label_w + px(18) + value_w) + px(20), min_width);
    box_h := lines.count * line_h + px(12);
    bx := x + px(14);
    by := y + px(18);
    if bx + box_w > draw.width - px(6) bx = x - px(14) - box_w;
    if by + box_h > draw.height - px(6) by = y - px(10) - box_h;
    bx = max(bx, px(6));
    by = max(by, px(6));
    box := snap(rect(bx, by, box_w, box_h));
    layer := draw_set_layer(.OVERLAY);
    push_clip_absolute(rect(0, 0, draw.width, draw.height));
    push_opacity(t);
    draw_shadow(box, px(3), px(12), theme.shadow, 0, px(4));
    draw_rect_outline(box, theme.panel_header, theme.border_strong, hairline(), px(3));
    ty := box.y + px(6);
    for lines {
        row := rect(box.x + px(10), ty, box.w - px(20), line_h);
        found, label, value := split_from_left(it, "\t");
        if found {
            draw_text_in_rect(fonts.regular, size, row, label, theme.text_muted);
            draw_text_in_rect(fonts.regular, size, row, value, theme.text, .RIGHT, style);
        } else {
            draw_text_in_rect(ifx it_index == 0 then fonts.semibold else fonts.regular, size, row, it, ifx it_index == 0 then theme.text else theme.text_secondary, .LEFT, style);
        }
        ty += line_h;
    }
    pop_opacity();
    pop_clip();
    draw_set_layer(layer);
}

//
// Dialogs: a dimmed backdrop and a centered panel that takes all input.
//

ui_modal_begin :: (width: float, height: float, t: float) -> Rect {
    ui.modal = true;
    ui.saved_layer = draw_set_layer(.OVERLAY);
    push_clip_absolute(rect(0, 0, draw.width, draw.height));
    ui.in_overlay = true;
    e := ease_out_cubic(t);
    draw_rect(rect(0, 0, draw.width, draw.height), rgba(0x000000, cast(u8) (120 * e)));
    r := snap(rect((draw.width - width) * 0.5, (draw.height - height) * 0.5 + px(10) * (1 - e), width, height));
    push_opacity(e);
    draw_shadow(r, px(theme.radius_panel), px(30), theme.shadow, 0, px(10));
    draw_rect_outline(r, theme.panel, theme.border_strong, hairline(), px(theme.radius_panel));
    return r;
}

ui_modal_end :: () {
    pop_opacity();
    ui.in_overlay = false;
    pop_clip();
    draw_set_layer(ui.saved_layer);
}

//
// Numbers that roll: when the text changes, characters that differ slide
// out and their replacements slide in, right to left like an odometer.
//

Roll_State :: struct {
    current:  [48] u8;
    current_count: s32;
    previous: [48] u8;
    previous_count: s32;
    t: float = 1;
    direction: float = 1;   // 1: new digits come up from below.
    last_frame: u64;
}

draw_rolling_text :: (id: UI_Id, font: *Font, size: float, r: Rect, text: string, color: Color, align := Text_Align.RIGHT, direction := 1.0, style := Text_Style.{}) -> float {
    st := table_find_pointer(*ui.rolls, id);
    if !st {
        st = table_add(*ui.rolls, id, .{});
        n := min(text.count, st.current.count);
        memcpy(st.current.data, text.data, n);
        st.current_count = cast(s32) n;
    }
    current := string.{st.current_count, st.current.data};
    if current != text && text.count <= st.current.count {
        memcpy(st.previous.data, st.current.data, st.current_count);
        st.previous_count = st.current_count;
        memcpy(st.current.data, text.data, text.count);
        st.current_count = cast(s32) text.count;
        // An interrupted roll restarts from what is mostly showing.
        st.t = 0;
        st.direction = direction;
    }
    DURATION :: 0.42;
    if st.t < 1 {
        st.t = min(st.t + ui.dt * ui.motion / DURATION, 1.0);
        if ui.motion <= 0 st.t = 1;
        ui.animating = true;
    }

    new_text := string.{st.current_count, st.current.data};
    width := measure_text(font, size, new_text, style);
    x := r.x;
    if align == .RIGHT  x = r.x + r.w - width;
    if align == .CENTER x = r.x + (r.w - width) * 0.5;
    x = floor(x + 0.5);
    baseline := text_baseline_in(font, size, r);

    if st.t >= 1 {
        draw_text(font, size, x, baseline, new_text, color, style);
        return width;
    }

    old_text := string.{st.previous_count, st.previous.data};
    old_width := measure_text(font, size, old_text, style);
    // The old text stays where it was drawn.
    old_x := r.x;
    if align == .RIGHT  old_x = r.x + r.w - old_width;
    if align == .CENTER old_x = r.x + (r.w - old_width) * 0.5;
    old_x = floor(old_x + 0.5);
    m := font_metrics(font, size);
    travel := m.ascent * 0.9 * st.direction;

    // A different shape (more digits, another label) can't roll digit by
    // digit without things jumping sideways: the whole text slides instead.
    if old_text.count != new_text.count || abs(old_width - width) > 0.5 || abs(old_x - x) > 0.5 {
        lt := ease_out_cubic(st.t);
        clip := rect(r.x - px(40), baseline - m.ascent - px(2), r.w + px(80), m.ascent + m.descent + px(4));
        push_clip(clip);
        push_opacity(1 - lt);
        draw_text(font, size, old_x, baseline - travel * lt, old_text, color, style);
        pop_opacity();
        push_opacity(lt);
        draw_text(font, size, x, baseline + travel * (1 - lt), new_text, color, style);
        pop_opacity();
        pop_clip();
        return width;
    }

    // Pair characters from the right; unchanged ones stand still.
    new_cps: [48] u32; new_xs: [48] float; nn := layout_code_points(font, size, new_text, x, style, *new_cps, *new_xs);
    old_cps: [48] u32; old_xs: [48] float; on := layout_code_points(font, size, old_text, old_x, style, *old_cps, *old_xs);
    clip := rect(r.x - px(40), baseline - m.ascent - px(2), r.w + px(80), m.ascent + m.descent + px(4));
    push_clip(clip);
    for k: 0..max(nn, on) - 1 {
        ni := nn - 1 - k;
        oi := on - 1 - k;
        nc := ifx ni >= 0 then new_cps[ni] else 0;
        oc := ifx oi >= 0 then old_cps[oi] else 0;
        delay := k * 0.045;
        lt := ease_out_cubic(clamp((st.t * DURATION - delay) / (DURATION * 0.7), 0, 1));
        if nc == oc && ni >= 0 && oi >= 0 && abs(new_xs[ni] - old_xs[oi]) < 0.5 {
            draw_code_point(font, size, new_xs[ni], baseline, nc, color, style);
            continue;
        }
        if oi >= 0 {
            push_opacity(1 - lt);
            draw_code_point(font, size, lerp(old_xs[oi], ifx ni >= 0 then new_xs[ni] else old_xs[oi], lt), baseline - travel * lt, oc, color, style);
            pop_opacity();
        }
        if ni >= 0 {
            push_opacity(lt);
            draw_code_point(font, size, new_xs[ni], baseline + travel * (1 - lt), nc, color, style);
            pop_opacity();
        }
    }
    pop_clip();
    return width;
}

#scope_file

layout_code_points :: (font: *Font, size: float, text: string, x0: float, style: Text_Style, cps: *[48] u32, xs: *[48] float) -> int {
    n := 0;
    i := 0;
    x := x0;
    while i < text.count && n < 48 {
        start := i;
        cp := next_code_point(text, *i);
        cps.*[n] = cp;
        xs.*[n] = x;
        x += measure_text(font, size, slice(text, start, i - start), style) + style.tracking;
        n += 1;
    }
    return n;
}

draw_code_point :: (font: *Font, size: float, x: float, baseline: float, cp: u32, color: Color, style: Text_Style) {
    buffer: [4] u8;
    n := 0;
    if cp < 0x80 { buffer[0] = cast(u8) cp; n = 1; }
    else if cp < 0x800 { buffer[0] = cast(u8) (0xC0 | (cp >> 6)); buffer[1] = cast(u8) (0x80 | (cp & 0x3F)); n = 2; }
    else if cp < 0x10000 { buffer[0] = cast(u8) (0xE0 | (cp >> 12)); buffer[1] = cast(u8) (0x80 | ((cp >> 6) & 0x3F)); buffer[2] = cast(u8) (0x80 | (cp & 0x3F)); n = 3; }
    else { buffer[0] = cast(u8) (0xF0 | (cp >> 18)); buffer[1] = cast(u8) (0x80 | ((cp >> 12) & 0x3F)); buffer[2] = cast(u8) (0x80 | ((cp >> 6) & 0x3F)); buffer[3] = cast(u8) (0x80 | (cp & 0x3F)); n = 4; }
    draw_text(font, size, x, baseline, string.{n, buffer.data}, color, style);
}
