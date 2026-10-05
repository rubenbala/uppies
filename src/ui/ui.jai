// Immediate-mode UI with retained animation state.
//
// Widgets are procedures called every frame with their rectangle; they draw
// themselves and report interaction (clicked, changed). There is no widget
// tree to keep in sync with the app's data. What has to survive between
// frames, the hover/press/position animations, lives in a small table keyed
// by the widget's id and is dropped once a widget stops being drawn.
//
// Animations are time-based and report `ui.animating` while they move, so
// the main loop renders exactly as long as something is in motion and then
// goes to sleep.

UI_Id :: u64;

UI_Widget :: struct {
    hover:  float;   // 0..1
    press:  float;   // 0..1
    spring: Spring;  // Widget-specific motion (toggle knob...).
    last_frame: u64;
}

UI_State :: struct {
    scale: float = 1;     // Pixels per logical unit.
    dt:    float;
    time:  float64;
    frame: u64;

    hot:    UI_Id;        // Under the mouse this frame.
    active: UI_Id;        // Being pressed or dragged.

    animating: bool;      // Something is still moving: render another frame.
    cursor: Cursor;

    widgets: Table(UI_Id, UI_Widget);
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
}

ui_end_frame :: () {
    if !input.mouse_down[Mouse_Button.LEFT] ui.active = 0;   // Its widget went away mid-press.
    platform_set_cursor(ui.cursor);

    // Forget widgets that were not drawn for a while.
    if ui.frame % 256 == 0 {
        stale: [..] UI_Id;
        stale.allocator = temp;
        for ui.widgets if ui.frame - it.last_frame > 256 array_add(*stale, it_index);
        for stale table_remove(*ui.widgets, it);
    }
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
    value.* = damp(value.*, target, speed, ui.dt);
    if abs(value.* - target) < 0.002 value.* = target;
    else ui.animating = true;
}

ui_spring :: (s: *Spring, target: float, stiffness := 300.0, damping_ratio := 0.75) -> float {
    s.target = target;
    if spring_update(s, ui.dt, stiffness, damping_ratio) ui.animating = true;
    return s.value;
}

Interaction :: struct {
    hovered: bool;   // Under the mouse (and nothing else is being pressed).
    pressed: bool;   // Mouse went down on it this frame.
    held:    bool;   // Mouse is down and it was pressed on it.
    clicked: bool;   // Released while over it, after being pressed on it.
}

ui_interact :: (id: UI_Id, r: Rect) -> Interaction {
    result: Interaction;
    mx, my := input.mouse_x, input.mouse_y;
    clip := draw.clip;
    over := input.mouse_inside && rect_contains(r, mx, my) && mx >= clip[0] && my >= clip[1] && mx < clip[2] && my < clip[3];
    result.hovered = over && (ui.active == 0 || ui.active == id);
    if result.hovered ui.hot = id;
    if result.hovered && input.mouse_pressed[Mouse_Button.LEFT] {
        ui.active = id;
        result.pressed = true;
    }
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

//
// Widgets.
//

ui_panel :: (area: Rect, elevation := 1.0, fill_color: Color = 0) {
    fill := ifx fill_color then fill_color else theme.surface;
    r := snap(area);
    radius := px(theme.radius_card);
    if elevation > 0 {
        draw_shadow(r, radius, px(18 * elevation), color_with_alpha(theme.shadow, 0.55), 0, px(6 * elevation));
        draw_shadow(r, radius, px(3), color_with_alpha(theme.shadow, 0.5), 0, px(1));
    }
    draw_rect_outline(r, fill, theme.border, hairline(), radius);
}

Button_Style :: enum u8 { PRIMARY; SECONDARY; GHOST; }

ui_button :: (label: string, r: Rect, style := Button_Style.SECONDARY) -> bool {
    id := ui_id(label);
    w := ui_widget(id);
    io := ui_interact(id, r);
    ui_animate(*w.hover, ifx io.hovered || io.held then 1.0 else 0.0, 16);
    ui_animate(*w.press, ifx io.held && io.hovered then 1.0 else 0.0, 28);
    if io.hovered ui.cursor = .HAND;

    // Pressing sinks the button by a pixel; hovering lifts its shadow.
    b := snap(rect_inset(r, px(1.0) * w.press));
    radius := px(theme.radius_control);
    border := hairline();
    white := rgb(0xFFFFFF);
    black := rgb(0x000000);
    text_color: Color;

    if style == {
        case .PRIMARY;
            draw_shadow(b, radius, px(10 + 8 * w.hover), color_with_alpha(theme.accent, 0.25 + 0.2 * w.hover - 0.2 * w.press), 0, px(3 + 2 * w.hover));
            top    := color_lerp(color_lerp(theme.accent_top,    white, 0.10 * w.hover), black, 0.12 * w.press);
            bottom := color_lerp(color_lerp(theme.accent_bottom, white, 0.08 * w.hover), black, 0.12 * w.press);
            r4 := float.[radius, radius, radius, radius];
            draw_rect_ex(b, top, bottom, r4, border, rgba(0xFFFFFF, cast(u8) (36 + 20 * w.hover)));
            text_color = theme.on_accent;
        case .SECONDARY;
            draw_shadow(b, radius, px(4), color_with_alpha(theme.shadow, 0.6 - 0.4 * w.press), 0, px(1));
            fill := color_lerp(color_lerp(theme.surface_raised, theme.surface_hover, w.hover), theme.surface, w.press);
            draw_rect_outline(b, fill, color_lerp(theme.border, theme.border_strong, w.hover), border, radius);
            text_color = theme.text;
        case .GHOST;
            draw_rect(b, color_with_alpha(theme.surface_hover, w.hover * (1 - 0.3 * w.press)), radius);
            text_color = color_lerp(theme.text_secondary, theme.text, w.hover);
    }
    draw_text_in_rect(fonts.semibold, px(theme.font_size_body), b, display_text(label), text_color, .CENTER);
    return io.clicked;
}

// A labeled switch filling the row r. Returns true when toggled.
ui_toggle :: (label: string, r: Rect, value: *bool) -> bool {
    id := ui_id(label);
    w, is_new := ui_widget(id);
    if is_new w.spring.value = ifx value.* then 1.0 else 0.0;   // Appear in place.
    io := ui_interact(id, r);
    if io.clicked value.* = !value.*;
    if io.hovered ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 16);
    t := ui_spring(*w.spring, ifx value.* then 1.0 else 0.0, 420, 0.62);

    draw_text_in_rect(fonts.regular, px(theme.font_size_body), r, display_text(label), theme.text, .LEFT);

    track_w := px(38);
    track_h := px(22);
    track := snap(rect(r.x + r.w - track_w, r.y + (r.h - track_h) * 0.5, track_w, track_h));
    off_color := color_lerp(theme.surface_hover, rgb(0x2E3440), w.hover);
    on_color  := color_lerp(theme.accent, theme.accent_top, w.hover);
    draw_rect_outline(track, color_lerp(off_color, on_color, clamp(t, 0, 1)), theme.border, hairline(), track.h * 0.5);

    knob_r := px(8);
    inset  := (track.h - 2 * knob_r) * 0.5;
    cx := track.x + inset + knob_r + (track.w - 2 * inset - 2 * knob_r) * t;
    cy := track.y + track.h * 0.5;
    knob := rect(cx - knob_r, cy - knob_r, 2 * knob_r, 2 * knob_r);
    draw_shadow(knob, knob_r, px(4), color_with_alpha(theme.shadow, 0.8), 0, px(1));
    draw_circle(cx, cy, knob_r, rgb(0xFFFFFF));
    return io.clicked;
}

// A labeled horizontal slider filling the row r (label above, track below).
ui_slider :: (label: string, r: Rect, value: *float, lo: float, hi: float, value_text: string) -> bool {
    id := ui_id(label);
    w := ui_widget(id);

    label_row := r;
    top := cut_top(*label_row, r.h * 0.5);
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), top, display_text(label), theme.text, .LEFT);
    draw_text_in_rect(fonts.regular, px(theme.font_size_body), top, value_text, theme.text_secondary, .RIGHT);

    track_area := label_row;
    io := ui_interact(id, track_area);
    if io.hovered || io.held ui.cursor = .HAND;
    ui_animate(*w.hover, ifx io.hovered || io.held then 1.0 else 0.0, 16);
    ui_animate(*w.press, ifx io.held then 1.0 else 0.0, 24);

    knob_r := px(7);
    track := snap(rect(track_area.x + knob_r, track_area.y + track_area.h * 0.5 - px(2), track_area.w - 2 * knob_r, px(4)));

    changed := false;
    if io.held {
        t := clamp((input.mouse_x - track.x) / max(track.w, 1.0), 0, 1);
        new_value := lo + (hi - lo) * t;
        if new_value != value.* { value.* = new_value; changed = true; }
    }

    t := clamp((value.* - lo) / (hi - lo), 0, 1);
    fill := track;
    fill.w = track.w * t;
    draw_rect(track, theme.surface_hover, track.h * 0.5);
    draw_rect_gradient(fill, theme.accent_top, theme.accent, track.h * 0.5);

    cx := track.x + track.w * t;
    cy := track.y + track.h * 0.5;
    radius := knob_r * (1 + 0.15 * w.hover + 0.1 * w.press);
    halo := radius + px(6) * w.hover;
    if w.hover > 0 draw_circle(cx, cy, halo, color_with_alpha(theme.accent_soft, w.hover));
    draw_shadow(rect(cx - radius, cy - radius, 2 * radius, 2 * radius), radius, px(4), color_with_alpha(theme.shadow, 0.8), 0, px(1));
    draw_circle(cx, cy, radius, rgb(0xFFFFFF));
    return changed;
}

// Thin horizontal line.
ui_divider :: (x: float, y: float, w: float) {
    draw_rect(snap(rect(x, y, w, hairline())), theme.divider);
}
