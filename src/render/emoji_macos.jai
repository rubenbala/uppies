// Color emoji on macOS. Apple Color Emoji is bitmaps (sbix) that FreeType
// can't decode here, and no other macOS font has emoji outlines, so Core Text
// draws each emoji sequence (a code point with its variation selector, skin
// tone, keycap or ZWJ partners, or a flag's pair) into an RGBA bitmap that
// font.jai packs into the color atlas.

// Whether Apple Color Emoji has the code point. Not cached: font.jai keeps
// the answer with each glyph.
emoji_has :: (code_point: u32) -> bool {
    font := emoji_font(EMOJI_PROBE_PX);
    if !font return false;
    chars: [2] u16;
    count := encode_utf16(code_point, *chars);
    glyphs: [2] u16;
    return CTFontGetGlyphsForCharacters(font, chars.data, glyphs.data, count) != 0;
}

Emoji_Bitmap :: struct {
    pixels:  [] u8;   // RGBA, premultiplied, sRGB; temporary storage.
    w, h:    s32;
    left:    s32;     // Ink offset from the pen position.
    top:     s32;     // Ink top above the baseline.
    advance: float;
}

// Draws the sequence at size_px. Pixels are cropped to the ink; w == 0 when
// nothing was drawn, or when the line is wider or taller than max_side.
emoji_rasterize :: (px: int, sequence: string, max_side: s32) -> Emoji_Bitmap, bool {
    result: Emoji_Bitmap;
    font := emoji_font(px);
    if !font return result, false;

    text := CF.CFStringCreateWithBytes(null, sequence.data, sequence.count, .kCFStringEncodingUTF8, false);
    if !text return result, false;
    defer CF.CFRelease(text);
    keys   := *void.[kCTFontAttributeName];
    values := *void.[font];
    attributes := CF.CFDictionaryCreate(null, keys.data, values.data, 1, *CF.kCFTypeDictionaryKeyCallBacks, *CF.kCFTypeDictionaryValueCallBacks);
    defer CF.CFRelease(attributes);
    attributed := CF.CFAttributedStringCreate(null, text, attributes);
    defer CF.CFRelease(attributed);
    line := CTLineCreateWithAttributedString(attributed);
    if !line return result, false;
    defer CF.CFRelease(line);

    ascent, descent, leading: CGFloat;
    result.advance = cast(float) CTLineGetTypographicBounds(line, *ascent, *descent, *leading);

    // A canvas a little larger than the line, then cropped to what was drawn.
    PAD :: 2;
    // Checked as floats, before the casts and the canvas, so there are no
    // megabytes allocated and scanned for a line the atlas can't hold anyway.
    // The advance stays, so the text after it keeps its place.
    if !(ceil(result.advance) + PAD * 2 <= xx max_side && ceil(ascent) + ceil(descent) + PAD * 2 <= xx max_side) {
        return result, true;
    }
    d := cast(s32) ceil(descent);
    w := cast(s32) ceil(result.advance) + PAD * 2;
    h := cast(s32) ceil(ascent) + d + PAD * 2;
    if w <= PAD * 2 || h <= PAD * 2 return result, true;
    pixels := NewArray(w * h * 4, u8,, temp);   // Zeroed: transparent.

    canvas := CGBitmapContextCreate(pixels.data, xx w, xx h, 8, xx (w * 4), emoji_color_space(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if !canvas return result, false;
    CGContextSetTextPosition(canvas, PAD, cast(CGFloat) (PAD + d));
    CTLineDraw(line, canvas);
    CGContextRelease(canvas);

    // Rows run top down in memory; the baseline is PAD + d up from the bottom.
    x0, y0, x1, y1 := w, h, 0, 0;
    for y: 0..h - 1 {
        row := pixels.data + y * w * 4;
        for x: 0..w - 1 {
            if row[x * 4 + 3] == 0 continue;
            x0 = min(x0, x); x1 = max(x1, x + 1);
            y0 = min(y0, y); y1 = max(y1, y + 1);
        }
    }
    if x0 >= x1 return result, true;

    result.w = xx (x1 - x0);
    result.h = xx (y1 - y0);
    result.left = xx (x0 - PAD);
    result.top  = xx ((h - PAD - d) - y0);
    result.pixels = NewArray(result.w * result.h * 4, u8,, temp);
    for y: 0..result.h - 1 {
        memcpy(result.pixels.data + y * result.w * 4, pixels.data + ((y0 + y) * w + x0) * 4, result.w * 4);
    }
    return result, true;
}

emoji_shutdown :: () {
    for emoji.fonts if it CF.CFRelease(it);
    if emoji.color_space CF.CFRelease(emoji.color_space);
    emoji = .{};
}

#scope_file

EMOJI_PROBE_PX :: 16;

Emoji_State :: struct {
    fonts: [1024] *void;        // CTFontRef per pixel size, created on first use.
    color_space: *void;
}

emoji: Emoji_State;

emoji_font :: (px: int) -> *void {
    if px <= 0 || px >= emoji.fonts.count return null;
    if !emoji.fonts[px] {
        NAME :: "AppleColorEmoji";
        name := CF.CFStringCreateWithBytes(null, NAME.data, NAME.count, .kCFStringEncodingUTF8, false);
        defer CF.CFRelease(name);
        emoji.fonts[px] = CTFontCreateWithName(name, cast(CGFloat) px, null);
    }
    return emoji.fonts[px];
}

emoji_color_space :: () -> *void {
    if !emoji.color_space emoji.color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return emoji.color_space;
}

encode_utf16 :: (code_point: u32, out: *[2] u16) -> s64 {
    if code_point < 0x10000 {
        out.*[0] = xx code_point;
        return 1;
    }
    c := code_point - 0x10000;
    out.*[0] = xx (0xD800 + (c >> 10));
    out.*[1] = xx (0xDC00 + (c & 0x3FF));
    return 2;
}

CF :: #import "macOS";

CGFloat :: float64;

coretext     :: #library,system "CoreText";
coregraphics :: #library,system "CoreGraphics";

kCTFontAttributeName: *void #elsewhere coretext;
CTFontCreateWithName :: (name: *void, size: CGFloat, matrix: *void) -> *void #foreign coretext;
CTFontGetGlyphsForCharacters :: (font: *void, characters: *u16, glyphs: *u16, count: s64) -> u8 #foreign coretext;
CTLineCreateWithAttributedString :: (attributed: *void) -> *void #foreign coretext;
CTLineGetTypographicBounds :: (line: *void, ascent: *CGFloat, descent: *CGFloat, leading: *CGFloat) -> float64 #foreign coretext;
CTLineDraw :: (line: *void, c: *void) #foreign coretext;

kCGImageAlphaPremultipliedLast :: 1;
kCGBitmapByteOrder32Big        :: 4 << 12;
kCGColorSpaceSRGB: *void #elsewhere coregraphics;
CGColorSpaceCreateWithName :: (name: *void) -> *void #foreign coregraphics;
CGBitmapContextCreate :: (data: *void, width: u64, height: u64, bits_per_component: u64, bytes_per_row: u64, space: *void, bitmap_info: u32) -> *void #foreign coregraphics;
CGContextSetTextPosition :: (c: *void, x: CGFloat, y: CGFloat) #foreign coregraphics;
CGContextRelease :: (c: *void) #foreign coregraphics;
