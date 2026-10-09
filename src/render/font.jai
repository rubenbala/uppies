// Text: FreeType rasterizes each glyph at the exact pixel size it is drawn at
// (so small UI text is as crisp as the platform's own), on demand, into one
// shared atlas texture. Glyphs are cached per font, pixel size, code point and
// horizontal subpixel position (quarter pixels), so text is laid out with the
// font's true advances yet every glyph lands on whole pixels, and drawing
// cached text costs one hash lookup per character.
//
// Sizes are in physical pixels (the UI multiplies by the DPI scale).
//
// On macOS, emoji are drawn in color by Core Text (emoji_macos.jai) into a
// second, RGBA atlas: a whole emoji sequence is then one glyph.

Font :: struct {
    id:          u8;
    path:        string;
    file_data:   string;      // FreeType reads the face from here; keep it alive.
    face:        FT.FT_Face;
    units_per_em: float;
    ascender:    float;       // Font units, above the baseline.
    descender:   float;       // Font units, below the baseline (positive).
    line_gap:    float;       // Font units.
    has_kerning: bool;
    current_px:  int;         // Pixel size the FreeType face is set to.
    tabular_advance: [128] float;   // Per pixel size: the widest digit (0 = not measured yet).
}

FONT_MAX_FONTS :: 16;

// Vertical metrics at a pixel size, rounded to pixels.
Font_Metrics :: struct {
    ascent:      float;
    descent:     float;
    line_height: float;
}

font_metrics :: (font: *Font, size_px: float) -> Font_Metrics {
    px := round_size(size_px);
    scale := px / font.units_per_em;
    m: Font_Metrics;
    m.ascent      = ceil(font.ascender * scale);
    m.descent     = ceil(font.descender * scale);
    m.line_height = ceil((font.ascender + font.descender + font.line_gap) * scale);
    return m;
}

// An atlas: a texture packed in shelves, single-channel coverage for text,
// RGBA for color emoji. The renderer uploads `dirty` each frame and
// recreates the texture when `generation` changes (it grew or was cleared).
Glyph_Atlas :: struct {
    size:       s32;
    bytes_per_pixel: s32 = 1;
    pixels:     [] u8;
    generation: u32;
    // Packing shelves.
    shelf_x, shelf_y, shelf_h: s32;
    // Region changed since the last upload (x0 >= x1 means clean).
    dirty_x0, dirty_y0, dirty_x1, dirty_y1: s32;
    clear_pending: bool;
}

glyph_atlas: Glyph_Atlas;
color_atlas := Glyph_Atlas.{bytes_per_pixel = 4};   // Color emoji (macOS); empty elsewhere.

fonts_init :: () -> bool {
    if FT.FT_Init_FreeType(*ft_library) != 0 {
        log_error("Could not initialize FreeType.\n");
        return false;
    }
    atlas_reset(*glyph_atlas, ATLAS_INITIAL_SIZE);
    #if OS == .MACOS atlas_reset(*color_atlas, COLOR_ATLAS_INITIAL_SIZE);
    return true;
}

fonts_shutdown :: () {
    for 0..loaded_font_count - 1 {
        font := *loaded_fonts[it];
        if font.face FT.FT_Done_Face(font.face);
        free(font.file_data);
    }
    loaded_font_count = 0;
    if ft_library FT.FT_Done_FreeType(ft_library);
    ft_library = null;
    deinit(*glyph_cache);
    array_free(glyph_atlas.pixels);
    array_free(color_atlas.pixels);
    #if OS == .MACOS emoji_shutdown();
}

// Loads the first font file that exists from candidates, relative paths
// being relative to the app's resources (the executable's directory, or
// Contents/Resources in a macOS app bundle).
load_font :: (candidates: [] string) -> *Font {
    for candidates {
        path := ifx is_absolute_path(it) then it else tprint("%/%", resource_dir, it);
        if !file_exists(path) continue;
        font := load_font_file(path);
        if font return font;
    }
    log_error("Could not load any font of %\n", candidates);
    return null;
}

load_font_file :: (path: string) -> *Font {
    if loaded_font_count >= FONT_MAX_FONTS return null;
    data, ok := read_entire_file(path);
    if !ok return null;

    face: FT.FT_Face;
    if FT.FT_New_Memory_Face(ft_library, data.data, xx data.count, 0, *face) != 0 {
        free(data);
        return null;
    }

    font := *loaded_fonts[loaded_font_count];   // Fixed storage: pointers stay valid.
    font.id           = cast(u8) loaded_font_count;
    loaded_font_count += 1;
    font.path         = copy_string(path);
    font.file_data    = data;
    font.face         = face;
    font.units_per_em = cast(float) face.units_per_EM;
    font.ascender     = cast(float) face.ascender;
    font.descender    = cast(float) -face.descender;
    font.line_gap     = max((cast(float) face.height) - font.ascender - font.descender, 0.0);
    font.has_kerning  = FT.FT_HAS_KERNING(face);
    log("Loaded font %\n", path);
    return font;
}

// Text options. Tabular figures give every digit the width of the widest
// one, so numbers in a column line up digit for digit whatever the font's
// default figures are. Tracking adds space between letters (small caps
// labels), in pixels.
Text_Style :: struct {
    tabular:  bool;
    tracking: float;
}

// Width in pixels of `text` drawn at size_px.
measure_text :: (font: *Font, size_px: float, text: string, style := Text_Style.{}) -> float {
    if !font return 0;
    px := round_size(size_px);
    tab_adv := ifx style.tabular then tabular_advance(font, px) else 0.0;
    pen: float;
    previous: u32;
    i := 0;
    while i < text.count {
        g, cp := next_glyph(font, px, text, *i);
        digit := style.tabular && is_digit_code_point(cp) && !g.color;
        if previous && font.has_kerning && !digit && g.source == font pen += kerning(font, px, previous, g.glyph_index);
        pen += ifx digit then tab_adv else g.advance;
        if g.advance > 0 || digit pen += style.tracking;
        previous = ifx g.source == font then g.glyph_index else 0;
    }
    if text.count pen -= style.tracking;
    return pen;
}

// Draws one line of text with its baseline at y. Returns the advance width.
draw_text :: (font: *Font, size_px: float, x: float, baseline: float, text: string, color: Color, style := Text_Style.{}) -> float {
    if !font return 0;
    px := round_size(size_px);
    tab_adv := ifx style.tabular then tabular_advance(font, px) else 0.0;
    base_y := floor(baseline + 0.5);
    pen := x;
    previous: u32;
    i := 0;
    while i < text.count {
        g, cp := next_glyph(font, px, text, *i);
        digit := style.tabular && is_digit_code_point(cp) && !g.color;
        if previous && font.has_kerning && !digit && g.source == font pen += kerning(font, px, previous, g.glyph_index);
        previous = ifx g.source == font then g.glyph_index else 0;

        if g.color {   // Drawn as is, on whole pixels; only its opacity follows the text color.
            slot := *g.bins[0];
            if slot.w > 0 {
                gx := floor(pen + 0.5) + slot.left;
                gy := base_y - slot.top;
                draw_color_glyph(gx, gy, gx + slot.w, gy + slot.h,
                                 xx slot.x, xx slot.y, xx (slot.x + slot.w), xx (slot.y + slot.h), color);
            }
            pen += g.advance + style.tracking;
            continue;
        }

        // Tabular digits sit centered in the widest digit's advance.
        glyph_x := ifx digit then pen + (tab_adv - g.advance) * 0.5 else pen;

        // Whole-pixel origin plus the nearest quarter-pixel rasterization.
        snapped  := floor(glyph_x * SUBPIXEL_BINS + 0.5) / SUBPIXEL_BINS;
        origin_x := floor(snapped);
        bin      := cast(int) ((snapped - origin_x) * SUBPIXEL_BINS);
        slot := *g.bins[bin];
        if !slot.rasterized rasterize_glyph(font, px, g, bin);
        if slot.w > 0 {
            gx := origin_x + slot.left;
            gy := base_y - slot.top;
            draw_glyph(gx, gy, gx + slot.w, gy + slot.h,
                       xx slot.x, xx slot.y, xx (slot.x + slot.w), xx (slot.y + slot.h), color);
        }
        pen += ifx digit then tab_adv else g.advance;
        if g.advance > 0 || digit pen += style.tracking;
    }
    if text.count pen -= style.tracking;
    return pen - x;
}

// Draws one glyph (an icon from a symbol font) centered on (cx, cy) by its
// actual ink bounds, snapped to whole pixels.
draw_glyph_centered :: (font: *Font, size_px: float, cx: float, cy: float, code_point: u32, color: Color) {
    if !font return;
    px := round_size(size_px);
    g := get_glyph(font, px, code_point);
    slot := *g.bins[0];
    if !slot.rasterized rasterize_glyph(font, px, g, 0);
    if slot.w <= 0 return;
    gx := floor(cx - slot.w * 0.5 + 0.5);
    gy := floor(cy - slot.h * 0.5 + 0.5);
    draw_glyph(gx, gy, gx + slot.w, gy + slot.h, xx slot.x, xx slot.y, xx (slot.x + slot.w), xx (slot.y + slot.h), color);
}

// The longest prefix of text that fits max_width, with an ellipsis when cut.
// Returns text itself when it fits.
fit_text :: (font: *Font, size_px: float, text: string, max_width: float, style := Text_Style.{}) -> string {
    if !font || max_width <= 0 return "";
    if measure_text(font, size_px, text, style) <= max_width return text;
    ELLIPSIS :: "…";
    budget := max_width - measure_text(font, size_px, ELLIPSIS);
    if budget <= 0 return "";
    px := round_size(size_px);
    pen: float;
    i := 0;
    cut := 0;
    while i < text.count {
        g := next_glyph(font, px, text, *i);
        pen += g.advance + style.tracking;
        if pen > budget break;
        cut = i;
    }
    // Don't leave a dangling space before the ellipsis.
    while cut > 0 && text[cut - 1] == #char " " cut -= 1;
    return tprint("%1%2", slice(text, 0, cut), ELLIPSIS);
}

#if OS == .MACOS #load "emoji_macos.jai";

is_digit_code_point :: inline (cp: u32) -> bool { return cp >= #char "0" && cp <= #char "9"; }

// Joiners and variation selectors shape emoji sequences; without a shaper
// they are simply skipped.
is_invisible_code_point :: inline (cp: u32) -> bool {
    return cp == 0x200B || cp == 0x200C || cp == 0x200D || cp == 0x2060 || (cp >= 0xFE00 && cp <= 0xFE0F) || cp == 0xFEFF;
}

fonts_add_fallback :: (font: *Font) {
    if !font || fallback_count >= fallback_fonts.count return;
    fallback_fonts[fallback_count] = font;
    fallback_count += 1;
}

// Whether a code point draws from `font` or one of the fallbacks.
font_has_glyph :: (font: *Font, code_point: u32) -> bool {
    if !font return false;
    if FT.FT_Get_Char_Index(font.face, xx code_point) return true;
    for 0..fallback_count - 1 if FT.FT_Get_Char_Index(fallback_fonts[it].face, xx code_point) return true;
    return false;
}

// Draws text vertically centered in r, aligned left, center or right.
Text_Align :: enum u8 { LEFT; CENTER; RIGHT; }

draw_text_in_rect :: (font: *Font, size_px: float, r: Rect, text: string, color: Color, align := Text_Align.LEFT, style := Text_Style.{}) -> float {
    if !font return 0;
    baseline := text_baseline_in(font, size_px, r);
    x := r.x;
    if align != .LEFT {
        w := measure_text(font, size_px, text, style);
        x = ifx align == .CENTER then r.x + (r.w - w) * 0.5 else r.x + r.w - w;
        x = floor(x + 0.5);
    }
    return draw_text(font, size_px, x, baseline, text, color, style);
}

// Like draw_text_in_rect, but cut with an ellipsis to fit r's width.
draw_text_fit :: (font: *Font, size_px: float, r: Rect, text: string, color: Color, align := Text_Align.LEFT, style := Text_Style.{}) -> float {
    return draw_text_in_rect(font, size_px, r, fit_text(font, size_px, text, r.w, style), color, align, style);
}

// The baseline that centers a line of text vertically in r.
text_baseline_in :: (font: *Font, size_px: float, r: Rect) -> float {
    m := font_metrics(font, size_px);
    // Center the cap-height-ish body: ascent and descent balanced.
    return r.y + (r.h + m.ascent - m.descent) * 0.5;
}

// Called at the start of a frame: a full atlas is cleared here, never in the
// middle of a frame whose instances still point into it.
fonts_begin_frame :: () {
    if !glyph_atlas.clear_pending && !color_atlas.clear_pending return;
    log("Glyph atlas full; clearing it.\n");
    for * glyph_cache {
        for * slot: it.bins slot.rasterized = false;
    }
    atlas_reset(*glyph_atlas, glyph_atlas.size);
    if color_atlas.size atlas_reset(*color_atlas, color_atlas.size);
}

// Pixel sizes change with DPI; glyphs at the old sizes can go.
fonts_clear_cache :: () {
    table_reset(*glyph_cache);
    for 0..loaded_font_count - 1 for * loaded_fonts[it].tabular_advance it.* = 0;
    atlas_reset(*glyph_atlas, glyph_atlas.size);
    if color_atlas.size atlas_reset(*color_atlas, color_atlas.size);
}

#scope_file

SUBPIXEL_BINS      :: 4;
ATLAS_INITIAL_SIZE :: 1024;
ATLAS_MAX_SIZE     :: 4096;
COLOR_ATLAS_INITIAL_SIZE :: 256;
COLOR_ATLAS_MAX_SIZE     :: 2048;
GLYPH_PADDING      :: 1;

FT_LOAD_TARGET_LIGHT :: 1 << 16;   // FT_LOAD_TARGET_(FT_RENDER_MODE_LIGHT)
FT_KERNING_UNFITTED  :: 1;

ft_library: FT.FT_Library;
loaded_fonts: [FONT_MAX_FONTS] Font;
loaded_font_count: int;

Glyph_Slot :: struct {
    x, y, w, h: s16;   // In the atlas.
    left, top:  s16;   // Bitmap offset from the pen position / baseline.
    rasterized: bool;
}

Glyph :: struct {
    glyph_index: u32;
    advance:     float;   // Pixels, unhinted.
    source:      *Font;   // The font that has the glyph: the requested one or a fallback.
    color:       bool;    // A color emoji sequence, in color_atlas (bins[0] only).
    emoji:       bool;    // macOS: Apple Color Emoji has the code point (it may start a color sequence).
    bins:        [SUBPIXEL_BINS] Glyph_Slot;
}

fallback_fonts: [4] *Font;
fallback_count: int;

glyph_cache: Table(u64, Glyph);

tabular_advance :: (font: *Font, px: int) -> float {
    if px < font.tabular_advance.count && font.tabular_advance[px] > 0 return font.tabular_advance[px];
    widest: float;
    for d: 0..9 widest = max(widest, get_glyph(font, px, cast(u32) (#char "0" + d)).advance);
    if px < font.tabular_advance.count font.tabular_advance[px] = widest;
    return widest;
}

round_size :: inline (size_px: float) -> int {
    return clamp(cast(int) (size_px + 0.5), 1, 1023);
}

glyph_key :: inline (font: *Font, px: int, code_point: u32) -> u64 {
    return ((cast(u64) font.id) << 40) | ((cast(u64) px) << 24) | cast(u64) code_point;
}

set_face_size :: inline (font: *Font, px: int) {
    if font.current_px == px return;
    FT.FT_Set_Pixel_Sizes(font.face, 0, xx px);
    font.current_px = px;
}

get_glyph :: (font: *Font, px: int, code_point: u32) -> *Glyph {
    key := glyph_key(font, px, code_point);
    g := table_find_pointer(*glyph_cache, key);
    if g return g;

    new_glyph: Glyph;
    new_glyph.source = font;
    if is_invisible_code_point(code_point) {   // Zero width, never drawn.
        for * new_glyph.bins it.rasterized = true;
        return table_add(*glyph_cache, key, new_glyph);
    }

    #if OS == .MACOS new_glyph.emoji = emoji_has(code_point);   // Asked once per glyph, not per frame.
    new_glyph.glyph_index = FT.FT_Get_Char_Index(font.face, xx code_point);
    if new_glyph.glyph_index == 0 {
        // Emoji and symbols the UI font lacks come from the fallbacks.
        for 0..fallback_count - 1 {
            fallback := fallback_fonts[it];
            if fallback == font continue;
            index := FT.FT_Get_Char_Index(fallback.face, xx code_point);
            if index {
                new_glyph.glyph_index = index;
                new_glyph.source = fallback;
                break;
            }
        }
    }
    source := new_glyph.source;
    set_face_size(source, px);
    if FT.FT_Load_Glyph(source.face, new_glyph.glyph_index, FT_LOAD_TARGET_LIGHT | FT.FT_LOAD_NO_BITMAP) == 0 {
        new_glyph.advance = source.face.glyph.linearHoriAdvance / 65536.0;
    }
    return table_add(*glyph_cache, key, new_glyph);
}

// The glyph at text[i], advancing i past it: one code point, or on macOS a
// whole emoji sequence drawn in color. Also returns the (first) code point.
// Plain text costs one glyph cache lookup per code point, as without emoji:
// the sequence is only looked at for code points the emoji font has.
next_glyph :: inline (font: *Font, px: int, text: string, i: *int) -> *Glyph, u32 {
    start := i.*;
    cp := next_code_point(text, i);
    g := get_glyph(font, px, cp);
    #if OS == .MACOS {
        // ASCII and Latin-1 draw in color only as keycaps (1️⃣): with U+FE0F next.
        if g.emoji && (cp >= 0xA9 || next_is_fe0f(text, i.*)) {
            end := color_sequence_end(g, text, cp, i.*);
            if end > 0 {
                i.* = end;
                return get_color_glyph(px, slice(text, start, end - start)), cp;
            }
        }
    }
    return g, cp;
}

#if OS == .MACOS {
    // Where the emoji sequence starting with cp (the next code point at
    // `after`) ends, when it is to be drawn in color; 0 when it isn't. A code
    // point the fonts lack draws in color, as does any asking for it with a
    // variation selector, skin tone, keycap or joiner; the symbol fonts'
    // outlines are kept for the rest (✈ without U+FE0F), as on Windows.
    color_sequence_end :: (g: *Glyph, text: string, cp: u32, after: int) -> int {
        next, next_end := peek_code_point(text, after);
        if next == 0xFE0E return 0;                // Text presentation asked for.

        if is_regional_indicator(cp) {             // Flags are pairs.
            return ifx is_regional_indicator(next) then next_end else after;
        }
        if !continues_emoji(next) && next != 0x200D && g.glyph_index != 0 return 0;

        end := after;
        while end < text.count {
            next, next_end = peek_code_point(text, end);
            if continues_emoji(next) {
                end = next_end;
            } else if next == 0x200D && next_end < text.count {
                _, end = peek_code_point(text, next_end);   // The joined emoji.
            } else {
                break;
            }
        }
        return end;
    }

    // Variation selector 16, keycap, skin tones, tags (subdivision flags).
    continues_emoji :: inline (cp: u32) -> bool {
        return cp == 0xFE0F || cp == 0x20E3 || (cp >= 0x1F3FB && cp <= 0x1F3FF) || (cp >= 0xE0020 && cp <= 0xE007F);
    }

    is_regional_indicator :: inline (cp: u32) -> bool { return cp >= 0x1F1E6 && cp <= 0x1F1FF; }

    next_is_fe0f :: inline (text: string, at: int) -> bool {   // U+FE0F is EF B8 8F.
        return at + 2 < text.count && text[at] == 0xEF && text[at + 1] == 0xB8 && text[at + 2] == 0x8F;
    }

    peek_code_point :: inline (text: string, at: int) -> u32, int {
        if at >= text.count return 0, at;
        i := at;
        cp := next_code_point(text, *i);
        return cp, i;
    }

    // Cached by the sequence's hash and pixel size, apart from any font's
    // glyphs (bit 63).
    get_color_glyph :: (px: int, sequence: string) -> *Glyph {
        h: u64 = 0xcbf29ce484222325;
        for 0..sequence.count - 1 { h ^= sequence[it]; h *= 0x100000001b3; }
        key := (1 << 63) | ((cast(u64) px) << 40) | (h & 0xFF_FFFF_FFFF);
        g := table_find_pointer(*glyph_cache, key);
        if g && g.bins[0].rasterized return g;

        new_glyph: Glyph;
        new_glyph.color = true;
        slot := *new_glyph.bins[0];
        slot.rasterized = true;   // Even on failure: don't retry every frame.
        bitmap, ok := emoji_rasterize(px, sequence);
        if ok {
            new_glyph.advance = bitmap.advance;
            if bitmap.w > 0 {
                x, y, placed := atlas_allocate(*color_atlas, bitmap.w, bitmap.h);
                if placed {
                    atlas_write(*color_atlas, x, y, bitmap.w, bitmap.h, bitmap.pixels.data, bitmap.w * 4);
                    slot.x, slot.y = xx x, xx y;
                    slot.w, slot.h = xx bitmap.w, xx bitmap.h;
                    slot.left = xx bitmap.left;
                    slot.top  = xx bitmap.top;
                }
            }
        }
        if g { g.* = new_glyph; return g; }   // Re-rasterized after the atlas was cleared.
        return table_add(*glyph_cache, key, new_glyph);
    }
}

kerning :: (font: *Font, px: int, left: u32, right: u32) -> float {
    set_face_size(font, px);
    k: FT.FT_Vector;
    if FT.FT_Get_Kerning(font.face, left, right, FT_KERNING_UNFITTED, *k) != 0 return 0;
    return k.x / 64.0;
}

rasterize_glyph :: (requested_font: *Font, px: int, g: *Glyph, bin: int) {
    slot := *g.bins[bin];
    slot.rasterized = true;   // Even on failure: don't retry every frame.
    if g.glyph_index == 0 && g.advance == 0 return;   // Invisible (joiners, selectors).

    font := ifx g.source then g.source else requested_font;
    set_face_size(font, px);
    face := font.face;
    if FT.FT_Load_Glyph(face, g.glyph_index, FT_LOAD_TARGET_LIGHT | FT.FT_LOAD_NO_BITMAP) != 0 return;

    // Shift the outline by the subpixel offset (26.6 fixed point) before
    // rendering, so the bitmap carries the fractional pen position.
    outline := *face.glyph.outline;
    shift := cast(s32) (bin * 64 / SUBPIXEL_BINS);
    for 0..outline.n_points - 1 outline.points[it].x += xx shift;

    if FT.FT_Render_Glyph(face.glyph, .NORMAL) != 0 return;
    bitmap := *face.glyph.bitmap;
    w := cast(s32) bitmap.width;
    h := cast(s32) bitmap.rows;
    if w == 0 || h == 0 return;   // Space and friends.

    x, y, ok := atlas_allocate(*glyph_atlas, w, h);
    if !ok return;
    atlas_write(*glyph_atlas, x, y, w, h, bitmap.buffer, bitmap.pitch);

    slot.x, slot.y = xx x, xx y;
    slot.w, slot.h = xx w, xx h;
    slot.left = xx face.glyph.bitmap_left;
    slot.top  = xx face.glyph.bitmap_top;
}

atlas_allocate :: (atlas: *Glyph_Atlas, w: s32, h: s32) -> s32, s32, bool {
    pw := w + GLYPH_PADDING;
    ph := h + GLYPH_PADDING;
    if atlas.shelf_x + pw > atlas.size {
        atlas.shelf_x = GLYPH_PADDING;
        atlas.shelf_y += atlas.shelf_h;
        atlas.shelf_h = 0;
    }
    if atlas.shelf_y + ph > atlas.size {
        max_size := ifx atlas.bytes_per_pixel == 1 then ATLAS_MAX_SIZE else COLOR_ATLAS_MAX_SIZE;
        if atlas.size < max_size {
            atlas_grow(atlas);
            gx, gy, grown_ok := atlas_allocate(atlas, w, h);
            return gx, gy, grown_ok;
        }
        atlas.clear_pending = true;   // Cleared at the start of the next frame.
        return 0, 0, false;
    }
    x := atlas.shelf_x;
    y := atlas.shelf_y;
    atlas.shelf_x += pw;
    atlas.shelf_h = max(atlas.shelf_h, ph);
    return x, y, true;
}

// Rows of w x h pixels from src (pitch bytes apart) to (x, y).
atlas_write :: (atlas: *Glyph_Atlas, x: s32, y: s32, w: s32, h: s32, src: *u8, pitch: s32) {
    bpp := atlas.bytes_per_pixel;
    for row: 0..h - 1 {
        dst := atlas.pixels.data + ((y + row) * atlas.size + x) * bpp;
        memcpy(dst, src + row * pitch, w * bpp);
    }
    atlas.dirty_x0 = min(atlas.dirty_x0, x);
    atlas.dirty_y0 = min(atlas.dirty_y0, y);
    atlas.dirty_x1 = max(atlas.dirty_x1, x + w);
    atlas.dirty_y1 = max(atlas.dirty_y1, y + h);
}

// Doubling keeps every glyph where it is: the old pixels become the top-left
// quarter. New shelves start below the old content, across the full width.
atlas_grow :: (atlas: *Glyph_Atlas) {
    bpp := atlas.bytes_per_pixel;
    old_size := atlas.size;
    new_size := old_size * 2;
    new_pixels := NewArray(new_size * new_size * bpp, u8);
    for row: 0..old_size - 1 memcpy(new_pixels.data + row * new_size * bpp, atlas.pixels.data + row * old_size * bpp, old_size * bpp);
    array_free(atlas.pixels);
    atlas.pixels  = new_pixels;
    atlas.size    = new_size;
    atlas.shelf_x = GLYPH_PADDING;
    atlas.shelf_y = old_size;
    atlas.shelf_h = 0;
    atlas.generation += 1;
    atlas_mark_all_dirty(atlas);
    log("% atlas grew to %x%\n", ifx bpp == 1 then "Glyph" else "Color glyph", new_size, new_size);
}

atlas_reset :: (atlas: *Glyph_Atlas, size: s32) {
    bytes := size * size * atlas.bytes_per_pixel;
    if atlas.pixels.count != bytes {
        array_free(atlas.pixels);
        atlas.pixels = NewArray(bytes, u8);
    } else {
        memset(atlas.pixels.data, 0, atlas.pixels.count);
    }
    atlas.size    = size;
    atlas.shelf_x = GLYPH_PADDING;
    atlas.shelf_y = GLYPH_PADDING;
    atlas.shelf_h = 0;
    atlas.clear_pending = false;
    atlas.generation += 1;
    atlas_mark_all_dirty(atlas);
}

atlas_mark_all_dirty :: (atlas: *Glyph_Atlas) {
    atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
    atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
}
