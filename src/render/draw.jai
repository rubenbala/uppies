// The draw list: what the UI produces each frame and the renderer consumes.
//
// Every primitive is one fixed-size instance that the GPU expands to a quad
// and shades with a distance function, so the whole UI (panels, borders,
// gradients, shadows, text, chart lines and areas) is one buffer upload and
// one draw call. Order of submission is order of painting, within a layer:
// everything on the overlay layer (menus, tooltips, dialogs) paints after
// the base layer, whenever in the frame it was submitted.
//
// All coordinates are physical pixels, origin top-left.

Draw_Kind :: enum u32 {
    RECT   :: 0;   // Rounded rectangle: gradient fill, optional border.
    GLYPH  :: 1;   // A glyph from the font atlas.
    SHADOW :: 2;   // Gaussian-blurred rounded rectangle.
    LINE   :: 3;   // Antialiased segment with round caps (charts).
    AREA   :: 4;   // Column with a sloped top edge down to a baseline (area charts).
}

// Keep in sync with Instance in src/render/d3d11/ui.hlsl and src/render/metal/ui.metal.
Draw_Instance :: struct {
    rect:         [4] float;   // x0 y0 x1 y1
    uv:           [4] float;   // Glyph: atlas texel rect. Line: endpoints. Area: top y at x0, x1.
    radii:        [4] float;   // Corner radii: tl, tr, br, bl.
    clip:         [4] float;   // x0 y0 x1 y1
    color0:       Color;       // Fill / gradient top / glyph / shadow / line color.
    color1:       Color;       // Gradient bottom.
    border_color: Color;
    kind:         Draw_Kind;
    params:       [4] float;   // x = border width, y = shadow sigma, z = line thickness.
}
#assert size_of(Draw_Instance) == 96;

Draw_Layer :: enum u8 { BASE; OVERLAY; }

Draw_List :: struct {
    instances: [..] Draw_Instance;
    overlay:   [..] Draw_Instance;
    layer: Draw_Layer;
    clip_stack: [..] [4] float;
    clip: [4] float;
    width, height: float;
    // Multiplies the alpha of everything drawn, for fading whole groups.
    opacity: float = 1;
    opacity_stack: [..] float;
}

draw: Draw_List;

draw_begin_frame :: (width: float, height: float) {
    draw.instances.count = 0;
    draw.overlay.count = 0;
    draw.layer = .BASE;
    draw.clip_stack.count = 0;
    draw.width  = width;
    draw.height = height;
    draw.clip   = .[0, 0, width, height];
    draw.opacity = 1;
    draw.opacity_stack.count = 0;
}

// The overlay paints over the base layer: appended at the end of the frame.
draw_end_frame :: () {
    if draw.overlay.count {
        old := draw.instances.count;
        array_resize(*draw.instances, old + draw.overlay.count, initialize = false);
        memcpy(draw.instances.data + old, draw.overlay.data, draw.overlay.count * size_of(Draw_Instance));
        draw.overlay.count = 0;
    }
}

// Switches layers; returns the previous one so callers can restore it.
draw_set_layer :: (layer: Draw_Layer) -> Draw_Layer {
    previous := draw.layer;
    draw.layer = layer;
    return previous;
}

push_opacity :: (opacity: float) {
    array_add(*draw.opacity_stack, draw.opacity);
    draw.opacity *= clamp(opacity, 0, 1);
}

pop_opacity :: () {
    assert(draw.opacity_stack.count > 0);
    draw.opacity = pop(*draw.opacity_stack);
}

// Clips everything drawn until the matching pop_clip to r (intersected with
// the current clip).
push_clip :: (r: Rect) {
    array_add(*draw.clip_stack, draw.clip);
    draw.clip[0] = max(draw.clip[0], r.x);
    draw.clip[1] = max(draw.clip[1], r.y);
    draw.clip[2] = min(draw.clip[2], r.x + r.w);
    draw.clip[3] = min(draw.clip[3], r.y + r.h);
}

// Replaces the clip outright (popovers escape the panel they were opened from).
push_clip_absolute :: (r: Rect) {
    array_add(*draw.clip_stack, draw.clip);
    draw.clip = .[r.x, r.y, r.x + r.w, r.y + r.h];
}

pop_clip :: () {
    assert(draw.clip_stack.count > 0);
    draw.clip = pop(*draw.clip_stack);
}

current_clip_rect :: () -> Rect {
    return rect(draw.clip[0], draw.clip[1], max(draw.clip[2] - draw.clip[0], 0.0), max(draw.clip[3] - draw.clip[1], 0.0));
}

draw_rect :: (r: Rect, color: Color, radius := 0.0) {
    draw_rect_ex(r, color, color, .[radius, radius, radius, radius]);
}

draw_rect_gradient :: (r: Rect, top: Color, bottom: Color, radius := 0.0) {
    draw_rect_ex(r, top, bottom, .[radius, radius, radius, radius]);
}

draw_rect_outline :: (r: Rect, fill: Color, border_color: Color, border_width: float, radius := 0.0) {
    draw_rect_ex(r, fill, fill, .[radius, radius, radius, radius], border_width, border_color);
}

draw_rect_ex :: (r: Rect, top_color: Color, bottom_color: Color, radii: [4] float, border_width := 0.0, border: Color = 0) {
    if r.w <= 0 || r.h <= 0 return;
    top, bottom, border_color := top_color, bottom_color, border;
    if draw.opacity < 1 {
        top, bottom, border_color = fade(top), fade(bottom), fade(border_color);
    }
    if ((top | bottom) >> 24) == 0 && (border_width <= 0 || (border_color >> 24) == 0) return;   // Invisible.
    inst := push_instance();
    inst.rect         = .[r.x, r.y, r.x + r.w, r.y + r.h];
    inst.radii        = radii;
    inst.color0       = top;
    inst.color1       = bottom;
    inst.border_color = border_color;
    inst.kind         = .RECT;
    inst.params[0]    = border_width;
}

draw_circle :: (cx: float, cy: float, radius: float, color: Color) {
    draw_rect(rect(cx - radius, cy - radius, 2 * radius, 2 * radius), color, radius);
}

// A soft shadow under the rounded rectangle r. `blur` is roughly the visible
// spread of the shadow in pixels.
draw_shadow :: (r: Rect, radius: float, blur: float, shadow_color: Color, offset_x := 0.0, offset_y := 0.0) {
    color := ifx draw.opacity < 1 then fade(shadow_color) else shadow_color;
    if (color >> 24) == 0 return;
    inst := push_instance();
    inst.rect      = .[r.x + offset_x, r.y + offset_y, r.x + r.w + offset_x, r.y + r.h + offset_y];
    inst.radii     = .[radius, radius, radius, radius];
    inst.color0    = color;
    inst.kind      = .SHADOW;
    inst.params[1] = max(blur * 0.5, 0.5);
}

// A straight segment with round caps, `thickness` pixels wide.
draw_line :: (x0: float, y0: float, x1: float, y1: float, thickness: float, line_color: Color) {
    color := ifx draw.opacity < 1 then fade(line_color) else line_color;
    if (color >> 24) == 0 return;
    half := thickness * 0.5;
    inst := push_instance();
    inst.rect      = .[min(x0, x1) - half, min(y0, y1) - half, max(x0, x1) + half, max(y0, y1) + half];
    inst.uv        = .[x0, y0, x1, y1];
    inst.color0    = color;
    inst.kind      = .LINE;
    inst.params[2] = thickness;
}

// The region between the segment (x0, top0)-(x1, top1) and the baseline y =
// bottom, filled with a vertical gradient. Hard edges left and right, so
// adjacent columns tile without seams; the sloped top is antialiased.
draw_area :: (x0: float, x1: float, top0: float, top1: float, bottom: float, top_color: Color, bottom_color: Color) {
    if x1 <= x0 return;
    c0 := ifx draw.opacity < 1 then fade(top_color) else top_color;
    c1 := ifx draw.opacity < 1 then fade(bottom_color) else bottom_color;
    if ((c0 | c1) >> 24) == 0 return;
    inst := push_instance();
    inst.rect   = .[x0, min(top0, top1), x1, max(bottom, max(top0, top1))];
    inst.uv     = .[top0, top1, bottom, 0];
    inst.color0 = c0;
    inst.color1 = c1;
    inst.kind   = .AREA;
}

draw_glyph :: inline (x0: float, y0: float, x1: float, y1: float, u0: float, v0: float, u1: float, v1: float, color: Color) {
    inst := push_instance();
    inst.rect   = .[x0, y0, x1, y1];
    inst.uv     = .[u0, v0, u1, v1];
    inst.color0 = ifx draw.opacity < 1 then fade(color) else color;
    inst.kind   = .GLYPH;
}

#scope_file

fade :: inline (c: Color) -> Color { return color_with_alpha(c, draw.opacity); }

push_instance :: inline () -> *Draw_Instance {
    inst := ifx draw.layer == .OVERLAY then array_add(*draw.overlay) else array_add(*draw.instances);
    inst.clip = draw.clip;
    return inst;
}
