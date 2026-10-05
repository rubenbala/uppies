// Small math helpers shared by every layer: rectangles, colors and
// frame-rate independent animation.

Rect :: struct {
    x, y, w, h: float;
}

rect :: inline (x: float, y: float, w: float, h: float) -> Rect {
    r: Rect = ---;
    r.x, r.y, r.w, r.h = x, y, w, h;
    return r;
}

rect_contains :: inline (r: Rect, px: float, py: float) -> bool {
    return px >= r.x && py >= r.y && px < r.x + r.w && py < r.y + r.h;
}

rect_inset :: inline (r: Rect, amount: float) -> Rect {
    return rect(r.x + amount, r.y + amount, max(r.w - 2 * amount, 0.0), max(r.h - 2 * amount, 0.0));
}

rect_inset_xy :: inline (r: Rect, ax: float, ay: float) -> Rect {
    return rect(r.x + ax, r.y + ay, max(r.w - 2 * ax, 0.0), max(r.h - 2 * ay, 0.0));
}

rect_intersect :: (a: Rect, b: Rect) -> Rect {
    x0 := max(a.x, b.x);
    y0 := max(a.y, b.y);
    x1 := min(a.x + a.w, b.x + b.w);
    y1 := min(a.y + a.h, b.y + b.h);
    return rect(x0, y0, max(x1 - x0, 0.0), max(y1 - y0, 0.0));
}

// Rect cutting: layout by slicing pieces off the edges of a rectangle.
// Each returns the piece and shrinks `r` by it.
cut_left :: (r: *Rect, amount: float) -> Rect {
    a := min(amount, r.w);
    piece := rect(r.x, r.y, a, r.h);
    r.x += a; r.w -= a;
    return piece;
}

cut_right :: (r: *Rect, amount: float) -> Rect {
    a := min(amount, r.w);
    r.w -= a;
    return rect(r.x + r.w, r.y, a, r.h);
}

cut_top :: (r: *Rect, amount: float) -> Rect {
    a := min(amount, r.h);
    piece := rect(r.x, r.y, r.w, a);
    r.y += a; r.h -= a;
    return piece;
}

cut_bottom :: (r: *Rect, amount: float) -> Rect {
    a := min(amount, r.h);
    r.h -= a;
    return rect(r.x, r.y + r.h, r.w, a);
}

// Splits r into `count` equal columns separated by `gap`.
split_columns :: (r: Rect, count: int, gap: float, index: int) -> Rect {
    w := (r.w - gap * (count - 1)) / count;
    return rect(r.x + index * (w + gap), r.y, w, r.h);
}

// Colors are sRGB, 8 bits per channel, packed as 0xAABBGGRR so the bytes in
// memory are R, G, B, A: what the GPU reads as R8G8B8A8_UNORM.
Color :: u32;

rgb :: inline (hex: u32) -> Color {
    return rgba(hex, 255);
}

rgba :: inline (hex: u32, alpha: u8) -> Color {
    r := (hex >> 16) & 0xFF;
    g := (hex >> 8) & 0xFF;
    b := hex & 0xFF;
    return r | (g << 8) | (b << 16) | ((cast(u32) alpha) << 24);
}

color_with_alpha :: inline (c: Color, alpha: float) -> Color {
    a := cast(u32) (clamp(alpha, 0, 1) * ((c >> 24) & 0xFF) + 0.5);
    return (c & 0x00FF_FFFF) | (a << 24);
}

color_lerp :: (a: Color, b: Color, t: float) -> Color {
    t = clamp(t, 0, 1);
    result: u32;
    for 0..3 {
        shift := cast(u32) (it * 8);
        ca := cast(float) ((a >> shift) & 0xFF);
        cb := cast(float) ((b >> shift) & 0xFF);
        result |= ((cast(u32) (ca + (cb - ca) * t + 0.5)) & 0xFF) << shift;
    }
    return result;
}

//
// Animation. Everything moves by time, never by frame count, so motion looks
// the same at 60 Hz or 360 Hz.
//

// Exponential approach toward target. `speed` is how fast in 1/seconds:
// after 1/speed seconds about 63% of the distance is covered.
damp :: inline (current: float, target: float, speed: float, dt: float) -> float {
    return target + (current - target) * exp(-speed * dt);
}

// A damped spring, for motion with a little overshoot and settle.
Spring :: struct {
    value:    float;
    velocity: float;
    target:   float;
}

// Stiffness ~ how fast, damping ratio < 1 overshoots, 1 is critically damped.
// Sub-steps so it is stable at any frame time. Returns true while moving.
spring_update :: (s: *Spring, dt: float, stiffness := 300.0, damping_ratio := 0.75) -> bool {
    MAX_STEP :: 1.0 / 240.0;
    damping := 2 * damping_ratio * sqrt(stiffness);
    remaining := dt;
    while remaining > 0 {
        h := min(remaining, MAX_STEP);
        accel := stiffness * (s.target - s.value) - damping * s.velocity;
        s.velocity += accel * h;   // Semi-implicit Euler.
        s.value    += s.velocity * h;
        remaining  -= h;
    }
    if abs(s.target - s.value) < 0.01 && abs(s.velocity) < 0.05 {
        s.value = s.target;
        s.velocity = 0;
        return false;
    }
    return true;
}

ease_out_cubic :: inline (t: float) -> float {
    t = clamp(t, 0, 1);
    u := 1 - t;
    return 1 - u * u * u;
}

ease_in_out_cubic :: inline (t: float) -> float {
    t = clamp(t, 0, 1);
    if t < 0.5 return 4 * t * t * t;
    u := -2 * t + 2;
    return 1 - u * u * u / 2;
}
