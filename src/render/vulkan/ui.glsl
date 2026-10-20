// The UI pipeline for Vulkan: a port of src/render/metal/ui.metal (itself a
// port of src/render/d3d11/ui.hlsl) with the same shading model, line for
// line where it can be. Every primitive is one 96-byte instance expanded to
// a quad here, so a whole frame is a single instanced draw with no vertex
// or index buffer: the instance's fields arrive as per-instance vertex
// attributes, as on Direct3D 11.
//
// Coordinates are physical pixels, origin top-left (Vulkan's clip space has
// y down, so no flip). Colors arrive as sRGB RGBA8 and are blended in sRGB
// space (the swapchain is B8G8R8A8_UNORM, not _SRGB). Output is
// premultiplied alpha.
//
// Both stages live here: build.jai compiles this file once with
// VERTEX_SHADER defined and once with FRAGMENT_SHADER.
//
// Keep the attributes in sync with Draw_Instance in src/render/draw.jai and
// the vertex input in src/render/vulkan/renderer_vulkan.jai.

#version 450

layout(push_constant) uniform Frame {
    vec2 viewport_size;          // Pixels.
    vec2 atlas_inv_size;         // 1 / glyph atlas size in texels.
    vec2 color_atlas_inv_size;   // 1 / color glyph (emoji) atlas size in texels.
} frame;

// KIND_RECT = 0 is the fall-through case in the fragment shader.
const uint KIND_GLYPH  = 1u;
const uint KIND_SHADOW = 2u;
const uint KIND_LINE   = 3u;
const uint KIND_AREA   = 4u;
const uint KIND_COLOR_GLYPH = 5u;

#ifdef VERTEX_SHADER

layout(location = 0) in vec4 in_rect;           // x0 y0 x1 y1
layout(location = 1) in vec4 in_uv;             // Glyph: atlas texel rect. Line: endpoints. Area: top y at x0, x1; baseline.
layout(location = 2) in vec4 in_radii;          // Corner radii: top-left, top-right, bottom-right, bottom-left.
layout(location = 3) in vec4 in_clip;           // x0 y0 x1 y1
layout(location = 4) in vec4 in_color0;         // Fill (gradient top), glyph color, shadow color.
layout(location = 5) in vec4 in_color1;         // Gradient bottom.
layout(location = 6) in vec4 in_border_color;
layout(location = 7) in uint in_kind;
layout(location = 8) in vec4 in_params;         // x = border width, y = shadow blur sigma, z = line thickness.

layout(location = 0) out vec2 out_pixel;        // Position in pixels, for the distance functions.
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out vec4 out_rect;
layout(location = 3) flat out vec4 out_radii;
layout(location = 4) flat out vec4 out_color0;
layout(location = 5) flat out vec4 out_color1;
layout(location = 6) flat out vec4 out_border_color;
layout(location = 7) flat out uint out_kind;
layout(location = 8) flat out vec4 out_params;
layout(location = 9) flat out vec4 out_data;    // The instance's raw uv (lines, areas).

void main() {
    // Grow the quad to hold the antialiased edge (and a shadow's blur), then
    // clip it on the CPU's behalf: clipped-away pixels are never shaded.
    // Areas tile side by side, so they only grow vertically (for the
    // antialiased top edge); their left and right edges stay hard.
    vec2 grow = vec2(1.0);
    if (in_kind == KIND_GLYPH || in_kind == KIND_COLOR_GLYPH) grow = vec2(0.0);
    if (in_kind == KIND_SHADOW) grow = vec2(3.0 * in_params.y + 1.0);
    if (in_kind == KIND_AREA)   grow = vec2(0.0, 1.0);

    vec2 lo = max(in_rect.xy - grow, in_clip.xy);
    vec2 hi = min(in_rect.zw + grow, in_clip.zw);
    hi = max(hi, lo);   // Fully clipped: a degenerate quad, culled by the rasterizer.

    vec2 corner = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));   // Triangle strip order.
    vec2 p = mix(lo, hi, corner);

    gl_Position = vec4(p * (2.0 / frame.viewport_size) - 1.0, 0.0, 1.0);
    out_pixel   = p;
    vec2 t      = (p - in_rect.xy) / max(in_rect.zw - in_rect.xy, vec2(1e-5));
    out_uv      = mix(in_uv.xy, in_uv.zw, t) * (in_kind == KIND_COLOR_GLYPH ? frame.color_atlas_inv_size : frame.atlas_inv_size);
    out_rect         = in_rect;
    out_radii        = in_radii;
    out_color0       = in_color0;
    out_color1       = in_color1;
    out_border_color = in_border_color;
    out_kind         = in_kind;
    out_params       = in_params;
    out_data         = in_uv;
}

#endif

#ifdef FRAGMENT_SHADER

layout(set = 0, binding = 0) uniform sampler2D glyph_atlas;
layout(set = 0, binding = 1) uniform sampler2D color_atlas;

layout(location = 0) in vec2 in_pixel;
layout(location = 1) in vec2 in_uv;
layout(location = 2) flat in vec4 in_rect;
layout(location = 3) flat in vec4 in_radii;
layout(location = 4) flat in vec4 in_color0;
layout(location = 5) flat in vec4 in_color1;
layout(location = 6) flat in vec4 in_border_color;
layout(location = 7) flat in uint in_kind;
layout(location = 8) flat in vec4 in_params;
layout(location = 9) flat in vec4 in_data;

layout(location = 0) out vec4 out_color;

float saturate(float x) { return clamp(x, 0.0, 1.0); }

// Signed distance to a rounded box centered at the origin, with a radius per
// corner (tl, tr, br, bl). Negative inside, in pixels.
float sd_round_box(vec2 p, vec2 half_size, vec4 radii) {
    float r = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w)
                        : (p.y < 0.0 ? radii.y : radii.z);
    r = min(r, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Shadow of a rounded box blurred by a Gaussian. Exact along x (erf), and
// integrated along y in a few samples. After Evan Wallace's derivation.
vec2 erf2(vec2 x) {
    vec2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.50662827 * sigma);
}

float shadow_x(float x, float y, float sigma, float corner, vec2 half_size) {
    float delta  = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (0.70710678 / sigma));
    return integral.y - integral.x;
}

float rounded_box_shadow(vec2 p, vec2 half_size, float corner, float sigma) {
    float low   = p.y - half_size.y;
    float high  = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end   = clamp( 3.0 * sigma, low, high);
    float step  = (end - start) / 4.0;
    float y     = start + step * 0.5;
    float value = 0.0;
    for (int i = 0; i < 4; i++) {
        value += shadow_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return value;
}

// Blending in sRGB space thins light text on dark backgrounds and thickens
// dark text on light ones. Bend the coverage toward what linear blending
// would give, a little less for dark text, which reads better slightly bold.
float text_coverage(float a, vec3 color) {
    a = saturate(a);
    float luma  = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float light = pow(a, 1.0 / 1.45);
    float dark  = 1.0 - pow(1.0 - a, 1.0 / 1.15);
    return mix(dark, light, luma);
}

// Interleaved gradient noise: +-half an 8-bit step, removes gradient banding.
float dither(vec2 pixel) {
    return (fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715)))) - 0.5) / 255.0;
}

// Distance from p to the segment a-b.
float sd_segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h);
}

void main() {
    if (in_kind == KIND_LINE) {
        float d = sd_segment(in_pixel, in_data.xy, in_data.zw) - in_params.z * 0.5;
        float a = saturate(0.5 - d) * in_color0.a;
        out_color = vec4(in_color0.rgb * a, a);
        return;
    }

    if (in_kind == KIND_AREA) {
        float tx    = saturate((in_pixel.x - in_rect.x) / max(in_rect.z - in_rect.x, 1e-5));
        float top   = mix(in_data.x, in_data.y, tx);
        float cover = saturate(in_pixel.y - top + 0.5) * saturate(in_data.z - in_pixel.y + 0.5);
        float t     = saturate((in_pixel.y - in_rect.y) / max(in_rect.w - in_rect.y, 1.0));
        vec4 fill   = mix(in_color0, in_color1, t);
        fill.rgb += dither(in_pixel);
        float a = fill.a * cover;
        out_color = vec4(fill.rgb * a, a);
        return;
    }

    if (in_kind == KIND_GLYPH) {
        float a = texture(glyph_atlas, in_uv).r;
        a = text_coverage(a, in_color0.rgb) * in_color0.a;
        out_color = vec4(in_color0.rgb * a, a);
        return;
    }

    // Premultiplied RGBA, faded by the instance's alpha.
    if (in_kind == KIND_COLOR_GLYPH) {
        out_color = texture(color_atlas, in_uv) * in_color0.a;
        return;
    }

    vec2 center    = (in_rect.xy + in_rect.zw) * 0.5;
    vec2 half_size = (in_rect.zw - in_rect.xy) * 0.5;
    vec2 p         = in_pixel - center;

    if (in_kind == KIND_SHADOW) {
        float sigma = max(in_params.y, 0.5);
        float a = rounded_box_shadow(p, half_size, min(in_radii.x, min(half_size.x, half_size.y)), sigma) * in_color0.a;
        a = saturate(a + dither(in_pixel));
        out_color = vec4(in_color0.rgb * a, a);
        return;
    }

    // Rounded rectangle: vertical gradient fill inside a border. A distance
    // of half a pixel either side of the edge is the antialiased band.
    float d = sd_round_box(p, half_size, in_radii);
    float t = saturate((in_pixel.y - in_rect.y) / max(in_rect.w - in_rect.y, 1.0));
    vec4 fill = mix(in_color0, in_color1, t);
    if (any(notEqual(in_color0, in_color1))) fill.rgb += dither(in_pixel);

    float border = in_params.x;
    float outer  = saturate(0.5 - d);
    float inner  = saturate(0.5 - (d + border));
    vec4 fill_pm   = vec4(fill.rgb * fill.a, fill.a);
    vec4 border_pm = vec4(in_border_color.rgb * in_border_color.a, in_border_color.a);
    out_color = mix(border_pm, fill_pm, border > 0.0 ? inner : 1.0) * outer;
}

#endif
