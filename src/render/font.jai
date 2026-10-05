// Text: FreeType rasterizes each glyph at the exact pixel size it is drawn at
// (so small UI text is as crisp as the platform's own), on demand, into one
// shared atlas texture. Glyphs are cached per font, pixel size, code point and
// horizontal subpixel position (quarter pixels), so text is laid out with the
// font's true advances yet every glyph lands on whole pixels, and drawing
// cached text costs one hash lookup per character.
//
// Sizes are in physical pixels (the UI multiplies by the DPI scale).

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

// The atlas: a single-channel coverage texture, packed in shelves. The
// renderer uploads `dirty` each frame and recreates the texture when
// `generation` changes (it grew or was cleared).
Glyph_Atlas :: struct {
    size:       s32;
    pixels:     [] u8;
    generation: u32;
    // Packing shelves.
    shelf_x, shelf_y, shelf_h: s32;
    // Region changed since the last upload (x0 >= x1 means clean).
    dirty_x0, dirty_y0, dirty_x1, dirty_y1: s32;
    clear_pending: bool;
}

glyph_atlas: Glyph_Atlas;

fonts_init :: () -> bool {
    if FT.FT_Init_FreeType(*ft_library) != 0 {
        log_error("Could not initialize FreeType.\n");
        return false;
    }
    atlas_reset(ATLAS_INITIAL_SIZE);
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
}

// Loads the first font file that exists from candidates, relative paths
// being relative to the executable's directory.
load_font :: (candidates: [] string) -> *Font {
    for candidates {
        path := ifx is_absolute_path(it) then it else tprint("%/%", exe_dir, it);
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

// Width in pixels of `text` drawn at size_px.
measure_text :: (font: *Font, size_px: float, text: string) -> float {
    px := round_size(size_px);
    pen: float;
    previous: u32;
    i := 0;
    while i < text.count {
        g := get_glyph(font, px, next_code_point(text, *i));
        if previous && font.has_kerning pen += kerning(font, px, previous, g.glyph_index);
        pen += g.advance;
        previous = g.glyph_index;
    }
    return pen;
}

// Draws one line of text with its baseline at y. Returns the advance width.
draw_text :: (font: *Font, size_px: float, x: float, baseline: float, text: string, color: Color) -> float {
    if !font return 0;
    px := round_size(size_px);
    base_y := floor(baseline + 0.5);
    pen := x;
    previous: u32;
    i := 0;
    while i < text.count {
        g := get_glyph(font, px, next_code_point(text, *i));
        if previous && font.has_kerning pen += kerning(font, px, previous, g.glyph_index);
        previous = g.glyph_index;

        // Whole-pixel origin plus the nearest quarter-pixel rasterization.
        snapped  := floor(pen * SUBPIXEL_BINS + 0.5) / SUBPIXEL_BINS;
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
        pen += g.advance;
    }
    return pen - x;
}

// Draws text vertically centered in r, aligned left, center or right.
Text_Align :: enum u8 { LEFT; CENTER; RIGHT; }

draw_text_in_rect :: (font: *Font, size_px: float, r: Rect, text: string, color: Color, align := Text_Align.LEFT) -> float {
    if !font return 0;
    m := font_metrics(font, size_px);
    // Center the cap-height-ish body: ascent and descent balanced.
    baseline := r.y + (r.h + m.ascent - m.descent) * 0.5;
    x := r.x;
    if align != .LEFT {
        w := measure_text(font, size_px, text);
        x = ifx align == .CENTER then r.x + (r.w - w) * 0.5 else r.x + r.w - w;
        x = floor(x + 0.5);
    }
    return draw_text(font, size_px, x, baseline, text, color);
}

// Called at the start of a frame: a full atlas is cleared here, never in the
// middle of a frame whose instances still point into it.
fonts_begin_frame :: () {
    if !glyph_atlas.clear_pending return;
    log("Glyph atlas full; clearing it.\n");
    for * glyph_cache {
        for * slot: it.bins slot.rasterized = false;
    }
    atlas_reset(glyph_atlas.size);
}

// Pixel sizes change with DPI; glyphs at the old sizes can go.
fonts_clear_cache :: () {
    table_reset(*glyph_cache);
    atlas_reset(glyph_atlas.size);
}

next_code_point :: (text: string, i: *int) -> u32 {
    b0 := cast(u32) text[i.*];
    i.* += 1;
    if b0 < 0x80 return b0;
    extra: int;
    cp: u32;
    if      (b0 & 0xE0) == 0xC0 { cp = b0 & 0x1F; extra = 1; }
    else if (b0 & 0xF0) == 0xE0 { cp = b0 & 0x0F; extra = 2; }
    else if (b0 & 0xF8) == 0xF0 { cp = b0 & 0x07; extra = 3; }
    else return 0xFFFD;
    for 1..extra {
        if i.* >= text.count return 0xFFFD;
        b := cast(u32) text[i.*];
        if (b & 0xC0) != 0x80 return 0xFFFD;
        cp = (cp << 6) | (b & 0x3F);
        i.* += 1;
    }
    return cp;
}

#scope_file

SUBPIXEL_BINS      :: 4;
ATLAS_INITIAL_SIZE :: 1024;
ATLAS_MAX_SIZE     :: 4096;
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
    bins:        [SUBPIXEL_BINS] Glyph_Slot;
}

glyph_cache: Table(u64, Glyph);

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
    new_glyph.glyph_index = FT.FT_Get_Char_Index(font.face, xx code_point);
    set_face_size(font, px);
    if FT.FT_Load_Glyph(font.face, new_glyph.glyph_index, FT_LOAD_TARGET_LIGHT | FT.FT_LOAD_NO_BITMAP) == 0 {
        new_glyph.advance = font.face.glyph.linearHoriAdvance / 65536.0;
    }
    return table_add(*glyph_cache, key, new_glyph);
}

kerning :: (font: *Font, px: int, left: u32, right: u32) -> float {
    set_face_size(font, px);
    k: FT.FT_Vector;
    if FT.FT_Get_Kerning(font.face, left, right, FT_KERNING_UNFITTED, *k) != 0 return 0;
    return k.x / 64.0;
}

rasterize_glyph :: (font: *Font, px: int, g: *Glyph, bin: int) {
    slot := *g.bins[bin];
    slot.rasterized = true;   // Even on failure: don't retry every frame.

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

    x, y, ok := atlas_allocate(w, h);
    if !ok return;

    atlas := *glyph_atlas;
    for row: 0..h - 1 {
        src := bitmap.buffer + row * bitmap.pitch;
        dst := atlas.pixels.data + (y + row) * atlas.size + x;
        memcpy(dst, src, w);
    }
    atlas.dirty_x0 = min(atlas.dirty_x0, x);
    atlas.dirty_y0 = min(atlas.dirty_y0, y);
    atlas.dirty_x1 = max(atlas.dirty_x1, x + w);
    atlas.dirty_y1 = max(atlas.dirty_y1, y + h);

    slot.x, slot.y = xx x, xx y;
    slot.w, slot.h = xx w, xx h;
    slot.left = xx face.glyph.bitmap_left;
    slot.top  = xx face.glyph.bitmap_top;
}

atlas_allocate :: (w: s32, h: s32) -> s32, s32, bool {
    atlas := *glyph_atlas;
    pw := w + GLYPH_PADDING;
    ph := h + GLYPH_PADDING;
    if atlas.shelf_x + pw > atlas.size {
        atlas.shelf_x = GLYPH_PADDING;
        atlas.shelf_y += atlas.shelf_h;
        atlas.shelf_h = 0;
    }
    if atlas.shelf_y + ph > atlas.size {
        if atlas.size < ATLAS_MAX_SIZE {
            atlas_grow();
            gx, gy, grown_ok := atlas_allocate(w, h);
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

// Doubling keeps every glyph where it is: the old pixels become the top-left
// quarter. New shelves start below the old content, across the full width.
atlas_grow :: () {
    atlas := *glyph_atlas;
    old_size := atlas.size;
    new_size := old_size * 2;
    new_pixels := NewArray(new_size * new_size, u8);
    for row: 0..old_size - 1 memcpy(new_pixels.data + row * new_size, atlas.pixels.data + row * old_size, old_size);
    array_free(atlas.pixels);
    atlas.pixels  = new_pixels;
    atlas.size    = new_size;
    atlas.shelf_x = GLYPH_PADDING;
    atlas.shelf_y = old_size;
    atlas.shelf_h = 0;
    atlas.generation += 1;
    atlas_mark_all_dirty();
    log("Glyph atlas grew to %x%\n", new_size, new_size);
}

atlas_reset :: (size: s32) {
    atlas := *glyph_atlas;
    if atlas.pixels.count != size * size {
        array_free(atlas.pixels);
        atlas.pixels = NewArray(size * size, u8);
    } else {
        memset(atlas.pixels.data, 0, atlas.pixels.count);
    }
    atlas.size    = size;
    atlas.shelf_x = GLYPH_PADDING;
    atlas.shelf_y = GLYPH_PADDING;
    atlas.shelf_h = 0;
    atlas.clear_pending = false;
    atlas.generation += 1;
    atlas_mark_all_dirty();
}

atlas_mark_all_dirty :: () {
    atlas := *glyph_atlas;
    atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
    atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
}
