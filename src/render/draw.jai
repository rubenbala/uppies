// The draw list: what the UI produces each frame and the renderer consumes.
//
// Every primitive is one fixed-size instance that the GPU expands to a quad
// and shades with a distance function, so the whole UI (panels, borders,
// gradients, shadows, text) is one buffer upload and one draw call. Order of
// submission is order of painting.
//
// All coordinates are physical pixels, origin top-left.

Draw_Kind :: enum u32 {
    RECT   :: 0;   // Rounded rectangle: gradient fill, optional border.
    GLYPH  :: 1;   // A glyph from the font atlas.
    SHADOW :: 2;   // Gaussian-blurred rounded rectangle.
}

// Keep in sync with Instance in src/render/d3d11/ui.hlsl.
Draw_Instance :: struct {
    rect:         [4] float;   // x0 y0 x1 y1
    uv:           [4] float;   // Glyph: atlas texel rect.
    radii:        [4] float;   // Corner radii: tl, tr, br, bl.
    clip:         [4] float;   // x0 y0 x1 y1
    color0:       Color;       // Fill / gradient top / glyph / shadow color.
    color1:       Color;       // Gradient bottom.
    border_color: Color;
    kind:         Draw_Kind;
    params:       [4] float;   // x = border width, y = shadow sigma.
}
#assert size_of(Draw_Instance) == 96;

Draw_List :: struct {
    instances: [..] Draw_Instance;
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
    draw.clip_stack.count = 0;
    draw.width  = width;
    draw.height = height;
    draw.clip   = .[0, 0, width, height];
    draw.opacity = 1;
    draw.opacity_stack.count = 0;
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

pop_clip :: () {
    assert(draw.clip_stack.count > 0);
    draw.clip = pop(*draw.clip_stack);
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
    inst := array_add(*draw.instances);
    inst.clip = draw.clip;
    return inst;
}
