// The UI pipeline: every primitive (rounded rectangle, border, gradient, soft
// shadow, glyph, chart line or area column) is one 96-byte instance expanded to a quad here, so a whole
// frame is a single instanced draw with no vertex or index buffer.
//
// Coordinates are physical pixels, origin top-left. Colors arrive as sRGB
// RGBA8 and are blended in sRGB space like browsers and design tools do, so
// what a designer picks is what appears. Output is premultiplied alpha.
//
// Keep Instance in sync with Draw_Instance in src/render/draw.jai.

cbuffer Frame : register(b0) {
    float2 viewport_size;     // Pixels.
    float2 atlas_inv_size;    // 1 / glyph atlas size in texels.
};

Texture2D<float> glyph_atlas : register(t0);
SamplerState     atlas_sampler : register(s0);

static const uint KIND_RECT   = 0;
static const uint KIND_GLYPH  = 1;
static const uint KIND_SHADOW = 2;
static const uint KIND_LINE   = 3;
static const uint KIND_AREA   = 4;

struct Instance {
    float4 rect         : RECT;     // x0 y0 x1 y1
    float4 uv           : UV;       // Glyph: atlas texel rect. Line: endpoints. Area: top y at x0, x1; baseline.
    float4 radii        : RADII;    // Corner radii: top-left, top-right, bottom-right, bottom-left.
    float4 clip         : CLIP;     // x0 y0 x1 y1
    float4 color0       : COLOR0;   // Fill (gradient top), glyph color, shadow color.
    float4 color1       : COLOR1;   // Gradient bottom.
    float4 border_color : COLOR2;
    uint   kind         : KIND;
    float4 params       : PARAMS;   // x = border width, y = shadow blur sigma, z = line thickness.
};

struct VS_Out {
    float4 position : SV_Position;
    float2 pixel    : PIXEL;        // Position in pixels, for the distance functions.
    float2 uv       : TEXCOORD0;
    nointerpolation float4 rect         : RECT;
    nointerpolation float4 radii        : RADII;
    nointerpolation float4 color0       : COLOR0;
    nointerpolation float4 color1       : COLOR1;
    nointerpolation float4 border_color : COLOR2;
    nointerpolation uint   kind         : KIND;
    nointerpolation float4 params       : PARAMS;
    nointerpolation float4 data         : DATA;     // The instance's raw uv (lines, areas).
};

VS_Out vs_main(uint vertex_id : SV_VertexID, Instance inst) {
    // Grow the quad to hold the antialiased edge (and a shadow's blur), then
    // clip it on the CPU's behalf: clipped-away pixels are never shaded.
    // Areas tile side by side, so they only grow vertically (for the
    // antialiased top edge); their left and right edges stay hard.
    float2 grow = 1.0;
    if (inst.kind == KIND_GLYPH)  grow = 0.0;
    if (inst.kind == KIND_SHADOW) grow = 3.0 * inst.params.y + 1.0;
    if (inst.kind == KIND_AREA)   grow = float2(0.0, 1.0);

    float2 lo = max(inst.rect.xy - grow, inst.clip.xy);
    float2 hi = min(inst.rect.zw + grow, inst.clip.zw);
    hi = max(hi, lo);   // Fully clipped: a degenerate quad, culled by the rasterizer.

    float2 corner = float2(vertex_id & 1, vertex_id >> 1);   // Triangle strip order.
    float2 p = lerp(lo, hi, corner);

    VS_Out o;
    o.position = float4(p * (2.0 / viewport_size) * float2(1, -1) + float2(-1, 1), 0, 1);
    o.pixel    = p;
    float2 t   = (p - inst.rect.xy) / max(inst.rect.zw - inst.rect.xy, 1e-5);
    o.uv       = lerp(inst.uv.xy, inst.uv.zw, t) * atlas_inv_size;
    o.rect         = inst.rect;
    o.radii        = inst.radii;
    o.color0       = inst.color0;
    o.color1       = inst.color1;
    o.border_color = inst.border_color;
    o.kind         = inst.kind;
    o.params       = inst.params;
    o.data         = inst.uv;
    return o;
}

// Signed distance to a rounded box centered at the origin, with a radius per
// corner (tl, tr, br, bl). Negative inside, in pixels.
float sd_round_box(float2 p, float2 half_size, float4 radii) {
    float r = p.x < 0 ? (p.y < 0 ? radii.x : radii.w)
                      : (p.y < 0 ? radii.y : radii.z);
    r = min(r, min(half_size.x, half_size.y));
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Shadow of a rounded box blurred by a Gaussian. Exact along x (erf), and
// integrated along y in a few samples. After Evan Wallace's derivation.
float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.50662827 * sigma);
}

float shadow_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta  = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (0.70710678 / sigma));
    return integral.y - integral.x;
}

float rounded_box_shadow(float2 p, float2 half_size, float corner, float sigma) {
    float low   = p.y - half_size.y;
    float high  = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end   = clamp( 3.0 * sigma, low, high);
    float step  = (end - start) / 4.0;
    float y     = start + step * 0.5;
    float value = 0.0;
    [unroll] for (int i = 0; i < 4; i++) {
        value += shadow_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return value;
}

// Blending in sRGB space thins light text on dark backgrounds and thickens
// dark text on light ones. Bend the coverage toward what linear blending
// would give, a little less for dark text, which reads better slightly bold.
float text_coverage(float a, float3 color) {
    a = saturate(a);
    float luma  = dot(color, float3(0.2126, 0.7152, 0.0722));
    float light = pow(a, 1.0 / 1.45);
    float dark  = 1.0 - pow(1.0 - a, 1.0 / 1.15);
    return lerp(dark, light, luma);
}

// Interleaved gradient noise: +-half an 8-bit step, removes gradient banding.
float dither(float2 pixel) {
    return (frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;
}

// Distance from p to the segment a-b.
float sd_segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h);
}

float4 ps_main(VS_Out i) : SV_Target {
    if (i.kind == KIND_LINE) {
        float d = sd_segment(i.pixel, i.data.xy, i.data.zw) - i.params.z * 0.5;
        float a = saturate(0.5 - d) * i.color0.a;
        return float4(i.color0.rgb * a, a);
    }

    if (i.kind == KIND_AREA) {
        float tx    = saturate((i.pixel.x - i.rect.x) / max(i.rect.z - i.rect.x, 1e-5));
        float top   = lerp(i.data.x, i.data.y, tx);
        float cover = saturate(i.pixel.y - top + 0.5) * saturate(i.data.z - i.pixel.y + 0.5);
        float t     = saturate((i.pixel.y - i.rect.y) / max(i.rect.w - i.rect.y, 1.0));
        float4 fill = lerp(i.color0, i.color1, t);
        fill.rgb += dither(i.pixel);
        float a = fill.a * cover;
        return float4(fill.rgb * a, a);
    }

    if (i.kind == KIND_GLYPH) {
        float a = glyph_atlas.Sample(atlas_sampler, i.uv);
        a = text_coverage(a, i.color0.rgb) * i.color0.a;
        return float4(i.color0.rgb * a, a);
    }

    float2 center    = (i.rect.xy + i.rect.zw) * 0.5;
    float2 half_size = (i.rect.zw - i.rect.xy) * 0.5;
    float2 p         = i.pixel - center;

    if (i.kind == KIND_SHADOW) {
        float sigma = max(i.params.y, 0.5);
        float a = rounded_box_shadow(p, half_size, min(i.radii.x, min(half_size.x, half_size.y)), sigma) * i.color0.a;
        a = saturate(a + dither(i.pixel));
        return float4(i.color0.rgb * a, a);
    }

    // Rounded rectangle: vertical gradient fill inside a border. A distance
    // of half a pixel either side of the edge is the antialiased band.
    float d = sd_round_box(p, half_size, i.radii);
    float t = saturate((i.pixel.y - i.rect.y) / max(i.rect.w - i.rect.y, 1.0));
    float4 fill = lerp(i.color0, i.color1, t);
    if (any(i.color0 != i.color1)) fill.rgb += dither(i.pixel);

    float border = i.params.x;
    float outer  = saturate(0.5 - d);
    float inner  = saturate(0.5 - (d + border));
    float4 fill_pm   = float4(fill.rgb * fill.a, fill.a);
    float4 border_pm = float4(i.border_color.rgb * i.border_color.a, i.border_color.a);
    return lerp(border_pm, fill_pm, border > 0 ? inner : 1.0) * outer;
}
