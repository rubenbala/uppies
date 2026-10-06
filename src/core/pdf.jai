// A small PDF writer: pages of text, lines, rectangles and paths.
//
// Text uses the standard Helvetica and Courier fonts, which every PDF reader
// has built in, so no font is embedded and a page of text is a few kilobytes.
// Text is UTF-8 in and WinAnsi (Windows-1252) in the file: English and
// Western European letters and the usual typography (– — ‘ ’ “ ” • … € × ›)
// print as themselves, a minus sign prints as an en dash, emoji are left out
// and anything else prints as "?".
//
// Coordinates are points (1/72 inch) from the top-left corner of the page,
// y down, like the rest of the app; the writer flips them for PDF. Colors are
// the app's Color; alpha is ignored except that a zero Color means "none".
//
// Everything lives in temporary storage, including the bytes pdf_finish
// returns, so build and save a document within one frame.
//
//     doc: Pdf_Document;
//     pdf_begin(*doc, "Title", "Uppies");
//     pdf_add_page(*doc);
//     pdf_text(*doc, 72, 72, .BOLD, 18, "Hello", rgb(0x111111));
//     bytes := pdf_finish(*doc);

PDF_A4_WIDTH  :: 595.28;
PDF_A4_HEIGHT :: 841.89;

Pdf_Font :: enum u8 { REGULAR; BOLD; MONO; }   // Helvetica, Helvetica-Bold, Courier.

Pdf_Document :: struct {
    width:   float = PDF_A4_WIDTH;
    height:  float = PDF_A4_HEIGHT;
    title:   string;       // Shown by readers in place of the file name.
    creator: string;       // The app that made it, in the file's properties.
    created: Timestamp;

    pages: [..] *String_Builder;   // Each page's content stream.
    page:  int = -1;               // Where drawing goes: an index into pages.
    path_fill, path_stroke: bool;  // The kind of path being built.
}

pdf_begin :: (doc: *Pdf_Document, title: string, creator: string, width := PDF_A4_WIDTH, height := PDF_A4_HEIGHT) {
    doc.* = .{};
    doc.width   = width;
    doc.height  = height;
    doc.title   = title;
    doc.creator = creator;
    doc.pages.allocator = temp;
}

// Adds a page at the end and directs drawing to it. Returns its index.
pdf_add_page :: (doc: *Pdf_Document) -> int {
    b := New(String_Builder,, temp);
    b.allocator = temp;
    array_add(*doc.pages, b);
    doc.page = doc.pages.count - 1;
    return doc.page;
}

// Draws one line of text with its baseline at y. `spacing` is extra space
// after every character (letter-spacing), in points. Returns the width drawn.
pdf_text :: (doc: *Pdf_Document, x: float, baseline: float, font: Pdf_Font, size: float, text: string, color: Color, spacing := 0.0) -> float {
    encoded := pdf_encode(text);
    if !encoded.count return 0;
    b := page_builder(doc);
    print_to_builder(b, "BT /F% % Tf % Tc % rg % % Td (", cast(int) font + 1, num(size), num(spacing), rgb_operands(color), num(x), num(doc.height - baseline));
    for cast([] u8) encoded {
        if it == #char "(" || it == #char ")" || it == #char "\\" { append(b, #char "\\"); append(b, it); }
        else if it < 0x80 append(b, it);
        else print_to_builder(b, "\\%", formatInt(it, base = 8, minimum_digits = 3));
    }
    append(b, ") Tj ET\n");
    return measure_encoded(font, size, encoded, spacing);
}

// The width of a line of text, in points.
pdf_measure :: (font: Pdf_Font, size: float, text: string, spacing := 0.0) -> float {
    return measure_encoded(font, size, pdf_encode(text), spacing);
}

// Breaks text into lines no wider than `width`: at spaces, at line breaks in
// the text, and between characters for a word too long for a line by
// itself (an id, a URL). An empty text is no lines.
pdf_wrap :: (font: Pdf_Font, size: float, text: string, width: float) -> [] string {
    lines: [..] string;
    lines.allocator = temp;
    if !text.count return lines;
    for paragraph: split(text, "\n",, temp) {
        p := paragraph;
        if p.count && p[p.count - 1] == #char "\r" p.count -= 1;
        i := 0;
        line_start := -1;
        line_end := 0;
        while true {
            while i < p.count && p[i] == #char " " i += 1;
            if i >= p.count break;
            word_start := i;
            while i < p.count && p[i] != #char " " i += 1;
            if line_start >= 0 && pdf_measure(font, size, slice(p, line_start, i - line_start)) <= width {
                line_end = i;
                continue;
            }
            if line_start >= 0 array_add(*lines, slice(p, line_start, line_end - line_start));
            line_start = word_start;
            line_end = i;
            // A word wider than the line: as much as fits (at least one
            // character) per line, the rest carrying on.
            while pdf_measure(font, size, slice(p, line_start, line_end - line_start)) > width {
                cut := line_start;
                j := line_start;
                while j < line_end {
                    k := j;
                    next_code_point(p, *k);
                    if cut > line_start && pdf_measure(font, size, slice(p, line_start, k - line_start)) > width break;
                    cut = k;
                    j = k;
                }
                if cut >= line_end break;
                array_add(*lines, slice(p, line_start, cut - line_start));
                line_start = cut;
            }
        }
        array_add(*lines, ifx line_start >= 0 then slice(p, line_start, line_end - line_start) else "");
    }
    return lines;
}

// The text, cut with an ellipsis to fit `width` if it has to be.
pdf_fit :: (font: Pdf_Font, size: float, text: string, width: float, spacing := 0.0) -> string {
    if pdf_measure(font, size, text, spacing) <= width return text;
    ELLIPSIS :: "…";
    room := width - pdf_measure(font, size, ELLIPSIS, spacing);
    end := 0;
    i := 0;
    while i < text.count {
        next_code_point(text, *i);
        if pdf_measure(font, size, slice(text, 0, i), spacing) > room break;
        end = i;
    }
    return tprint("%1%2", trim_right(slice(text, 0, end)), ELLIPSIS);
}

pdf_rect :: (doc: *Pdf_Document, x: float, y: float, w: float, h: float, fill: Color, radius := 0.0) {
    pdf_path_begin(doc, fill = fill);
    pdf_rect_path(doc, x, y, w, h, radius);
    pdf_path_end(doc);
}

// A rectangle shaded from `top` to `bottom`.
pdf_rect_gradient :: (doc: *Pdf_Document, x: float, y: float, w: float, h: float, top: Color, bottom: Color, radius := 0.0) {
    BANDS :: 32;   // Finer than print can resolve over a small mark.
    pdf_push_clip(doc, x, y, w, h, radius);
    band := h / BANDS;
    for 0..BANDS - 1 {
        // Each band overlaps the next a little, so no seam shows between them.
        pdf_rect(doc, x, y + it * band, w, band + ifx it < BANDS - 1 then band * 0.5 else 0.0, color_lerp(top, bottom, (it + 0.5) / BANDS));
    }
    pdf_pop_clip(doc);
}

pdf_line :: (doc: *Pdf_Document, x0: float, y0: float, x1: float, y1: float, width: float, color: Color, round := false) {
    pdf_path_begin(doc, stroke = color, width = width, round = round);
    pdf_move_to(doc, x0, y0);
    pdf_line_to(doc, x1, y1);
    pdf_path_end(doc);
}

// Paths: pdf_path_begin, then pdf_move_to / pdf_line_to / pdf_curve_to /
// pdf_close_path, then pdf_path_end fills and/or strokes it. `round` gives
// strokes round caps and joins.
pdf_path_begin :: (doc: *Pdf_Document, fill: Color = 0, stroke: Color = 0, width := 1.0, round := false) {
    b := page_builder(doc);
    doc.path_fill = fill != 0;
    doc.path_stroke = stroke != 0;
    append(b, "q ");
    if doc.path_fill print_to_builder(b, "% rg ", rgb_operands(fill));
    if doc.path_stroke {
        print_to_builder(b, "% RG % w ", rgb_operands(stroke), num(width));
        if round append(b, "1 J 1 j ");
    }
    append(b, "\n");
}

pdf_path_end :: (doc: *Pdf_Document) {
    op := ifx doc.path_fill && doc.path_stroke then "B" else ifx doc.path_fill then "f" else ifx doc.path_stroke then "S" else "n";
    print_to_builder(page_builder(doc), "% Q\n", op);
}

pdf_move_to :: (doc: *Pdf_Document, x: float, y: float) {
    print_to_builder(page_builder(doc), "% % m\n", num(x), num(doc.height - y));
}

pdf_line_to :: (doc: *Pdf_Document, x: float, y: float) {
    print_to_builder(page_builder(doc), "% % l\n", num(x), num(doc.height - y));
}

// A cubic Bézier from the current point through controls 1 and 2 to 3.
pdf_curve_to :: (doc: *Pdf_Document, x1: float, y1: float, x2: float, y2: float, x3: float, y3: float) {
    print_to_builder(page_builder(doc), "% % % % % % c\n", num(x1), num(doc.height - y1), num(x2), num(doc.height - y2), num(x3), num(doc.height - y3));
}

pdf_close_path :: (doc: *Pdf_Document) {
    append(page_builder(doc), "h\n");
}

// Adds a rectangle, with rounded corners if radius > 0, to the current path.
pdf_rect_path :: (doc: *Pdf_Document, x: float, y: float, w: float, h: float, radius := 0.0) {
    r := min(radius, w * 0.5, h * 0.5);
    if r <= 0 {
        print_to_builder(page_builder(doc), "% % % % re\n", num(x), num(doc.height - y - h), num(w), num(h));
        return;
    }
    k := r * 0.5523;   // Control distance that makes a quarter Bézier a near-perfect circle.
    pdf_move_to(doc, x + r, y);
    pdf_line_to(doc, x + w - r, y);
    pdf_curve_to(doc, x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pdf_line_to(doc, x + w, y + h - r);
    pdf_curve_to(doc, x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pdf_line_to(doc, x + r, y + h);
    pdf_curve_to(doc, x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pdf_line_to(doc, x, y + r);
    pdf_curve_to(doc, x, y + r - k, x + r - k, y, x + r, y);
    pdf_close_path(doc);
}

// Drawing until the matching pdf_pop_clip only shows inside the rectangle.
pdf_push_clip :: (doc: *Pdf_Document, x: float, y: float, w: float, h: float, radius := 0.0) {
    append(page_builder(doc), "q\n");
    pdf_rect_path(doc, x, y, w, h, radius);
    append(page_builder(doc), "W n\n");
}

pdf_pop_clip :: (doc: *Pdf_Document) {
    append(page_builder(doc), "Q\n");
}

// The finished file (temporary storage).
pdf_finish :: (doc: *Pdf_Document) -> string {
    if !doc.pages.count pdf_add_page(doc);

    // Objects: 1 catalog, 2 page tree, 3 document info, 4.. the fonts, then
    // each page followed by its content stream.
    FIRST_FONT :: 4;
    font_count := enum_highest_value(Pdf_Font) + 1;
    first_page := FIRST_FONT + font_count;
    object_count := first_page + doc.pages.count * 2;   // Including object 0.

    out: String_Builder;
    out.allocator = temp;
    offsets := NewArray(object_count, int,, temp);
    begin_object :: (n: int) #expand {
        `offsets[n] = builder_string_length(*`out);
        print_to_builder(*`out, "% 0 obj\n", n);
    }

    // The second line's bytes above 127 mark the file as binary for tools
    // that guess.
    append(*out, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    begin_object(1);
    append(*out, "<< /Type /Catalog /Pages 2 0 R /ViewerPreferences << /DisplayDocTitle true >> >>\nendobj\n");

    begin_object(2);
    append(*out, "<< /Type /Pages /Kids [");
    for 0..doc.pages.count - 1 print_to_builder(*out, "% 0 R ", first_page + it * 2);
    print_to_builder(*out, "] /Count % /MediaBox [0 0 % %] /Resources << /Font <<", doc.pages.count, num(doc.width), num(doc.height));
    for 0..font_count - 1 print_to_builder(*out, " /F% % 0 R", it + 1, FIRST_FONT + it);
    append(*out, " >> >> >>\nendobj\n");

    begin_object(3);
    append(*out, "<< /Title ");
    append_text_string(*out, doc.title);
    append(*out, " /Creator ");
    append_text_string(*out, doc.creator);
    append(*out, " /Producer ");
    append_text_string(*out, doc.creator);
    if doc.created.utc {
        t := doc.created;
        d := civil_from_days(ts_day(t));
        secs := ts_local_seconds(t) - ts_day(t) * SECONDS_PER_DAY;
        o := abs(t.offset);
        print_to_builder(*out, " /CreationDate (D:%1%2%3%4%5%6%7%8'%9')", d.year, pad2(d.month), pad2(d.day), pad2(secs / 3600), pad2((secs / 60) % 60), pad2(secs % 60),
                         ifx t.offset < 0 then "-" else "+", pad2(o / 60), pad2(o % 60));
    }
    append(*out, " >>\nendobj\n");

    for 0..font_count - 1 {
        begin_object(FIRST_FONT + it);
        print_to_builder(*out, "<< /Type /Font /Subtype /Type1 /BaseFont /% /Encoding /WinAnsiEncoding >>\nendobj\n", FONT_NAMES[it]);
    }

    for page, index: doc.pages {
        n := first_page + index * 2;
        begin_object(n);
        print_to_builder(*out, "<< /Type /Page /Parent 2 0 R /Contents % 0 R >>\nendobj\n", n + 1);
        content := builder_to_string(page,, temp);
        begin_object(n + 1);
        print_to_builder(*out, "<< /Length % >>\nstream\n", content.count);
        append(*out, content);
        append(*out, "\nendstream\nendobj\n");
    }

    // Each cross-reference entry is exactly 20 bytes.
    xref := builder_string_length(*out);
    print_to_builder(*out, "xref\n0 %\n0000000000 65535 f \n", object_count);
    for 1..object_count - 1 print_to_builder(*out, "% 00000 n \n", formatInt(offsets[it], minimum_digits = 10));
    print_to_builder(*out, "trailer\n<< /Size % /Root 1 0 R /Info 3 0 R >>\nstartxref\n%\n", object_count, xref);
    append(*out, "%%EOF\n");
    return builder_to_string(*out,, temp);
}

// UTF-8 to the bytes the standard fonts draw (WinAnsi). Temporary storage.
pdf_encode :: (text: string) -> string {
    ascii := true;
    for cast([] u8) text if it >= 0x80 || it < 0x20 { ascii = false; break; }
    if ascii return text;

    out: [..] u8;
    out.allocator = temp;
    array_reserve(*out, text.count);
    i := 0;
    while i < text.count {
        cp := next_code_point(text, *i);
        c := win_ansi_from_code_point(cp);
        if c >= 0 array_add(*out, cast(u8) c);
    }
    return string.{out.count, out.data};
}

#scope_file

FONT_NAMES :: string.["Helvetica", "Helvetica-Bold", "Courier"];

page_builder :: (doc: *Pdf_Document) -> *String_Builder {
    if doc.page < 0 || doc.page >= doc.pages.count pdf_add_page(doc);
    return doc.pages[doc.page];
}

// Numbers in content streams: two decimals at most, trailing zeros dropped.
// (Formatted here: a FormatFloat would point at `v` after it has gone.)
num :: (v: float) -> string {
    return trim_right(tprint("%", formatFloat(v, trailing_width = 2)));
}

rgb_operands :: (c: Color) -> string {
    channel :: (c: Color, shift: u32) -> string {
        return trim_right(tprint("%", formatFloat(((c >> shift) & 0xFF) / 255.0, trailing_width = 3)));
    }
    return tprint("% % %", channel(c, 0), channel(c, 8), channel(c, 16));
}

measure_encoded :: (font: Pdf_Font, size: float, encoded: string, spacing: float) -> float {
    units := 0;
    if font == .MONO {
        units = encoded.count * 600;   // Courier: every character is 600 units.
    } else {
        widths := ifx font == .BOLD then HELVETICA_BOLD_WIDTHS else HELVETICA_WIDTHS;
        for cast([] u8) encoded if it >= 32 units += widths[it - 32];
    }
    return units * size / 1000 + spacing * encoded.count;
}

// A string for the document information (title, creator): UTF-16 with a
// byte order mark, in hex, so any character survives.
append_text_string :: (b: *String_Builder, text: string) {
    append(b, "<FEFF");
    i := 0;
    while i < text.count {
        cp := next_code_point(text, *i);
        if cp >= 0x10000 {
            v := cp - 0x10000;
            print_to_builder(b, "%", formatInt(0xD800 + (v >> 10), base = 16, minimum_digits = 4));
            print_to_builder(b, "%", formatInt(0xDC00 + (v & 0x3FF), base = 16, minimum_digits = 4));
        } else {
            print_to_builder(b, "%", formatInt(cp, base = 16, minimum_digits = 4));
        }
    }
    append(b, ">");
}

// The WinAnsi byte for a code point, or -1 to leave it out.
win_ansi_from_code_point :: (cp: u32) -> int {
    if cp >= 0x20 && cp < 0x7F return xx cp;
    if cp >= 0xA0 && cp <= 0xFF return xx cp;
    if cp == #char "\t" return #char " ";
    if cp < 0x20 || cp == 0x7F return -1;
    if cp == 0x2212 return 0x96;                                          // Minus sign: en dash.
    if (cp >= 0x2000 && cp <= 0x200A) || cp == 0x202F || cp == 0x205F return #char " ";   // Thin, narrow and other spaces.
    // Joiners, variation selectors, skin tones: parts of emoji, invisible
    // on their own. Emoji and pictographs have no WinAnsi form and are
    // left out rather than printed as "?".
    if cp == 0x200B || cp == 0x200C || cp == 0x200D || cp == 0x2060 || cp == 0xFEFF || (cp >= 0xFE00 && cp <= 0xFE0F) return -1;
    if (cp >= 0x2600 && cp <= 0x27BF) || (cp >= 0x2B00 && cp <= 0x2BFF) || (cp >= 0x1F000 && cp <= 0x1FAFF) || (cp >= 0xE0000 && cp <= 0xE007F) return -1;
    for WIN_ANSI_HIGH if it == cp return 0x80 + it_index;
    return #char "?";
}

// What WinAnsi puts at 0x80..0x9F (zero: nothing).
WIN_ANSI_HIGH :: u32.[
    0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017D, 0,
    0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0,      0x017E, 0x0178,
];

// Advance widths of the standard fonts (Adobe's AFM files) in 1/1000 em,
// for WinAnsi codes 32..255.
HELVETICA_WIDTHS :: u16.[
     278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
     556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
     667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
     333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
     556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 278,
     556, 278, 222, 556, 333,1000, 556, 556, 333,1000, 667, 333,1000, 278, 611, 278,
     278, 222, 222, 333, 333, 350, 556,1000, 333,1000, 500, 333, 944, 278, 500, 667,
     278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333,
     400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611,
     667, 667, 667, 667, 667, 667,1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
     722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
     556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278,
     556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500,
];

HELVETICA_BOLD_WIDTHS :: u16.[
     278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
     556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
     975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
     667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
     333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
     611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 278,
     556, 278, 278, 556, 500,1000, 556, 556, 333,1000, 667, 333,1000, 278, 611, 278,
     278, 278, 278, 500, 500, 350, 556,1000, 333,1000, 556, 333, 944, 278, 500, 667,
     278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333,
     400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611,
     722, 722, 722, 722, 722, 722,1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
     722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
     556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278,
     611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556,
];

#assert HELVETICA_WIDTHS.count == 224 && HELVETICA_BOLD_WIDTHS.count == 224;
