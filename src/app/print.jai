// Printing: documents made from what the app holds, saved as PDFs.
//
// A Print_Doc is a PDF (core/pdf.jai) with the app's page design: the
// Uppies header on every page, then blocks that flow down the page and onto
// new pages as they fill (a title, an amount, sections of label/value
// fields, tables, notes), and on every page a footer saying the document
// was made with Uppies, when, and which page it is.
//
// Each kind of document is a procedure that builds one and returns the file;
// print_transaction.jai has a transaction, several transactions one after
// another, and a statement of several. Another (an account's statement, a
// tag's report) is the same shape:
//
//     doc: Print_Doc;
//     print_begin(*doc, "Statement", title);
//     print_title(*doc, ...);
//     print_section(*doc, "Summary");
//     print_field(*doc, "Opening balance", ...);
//     bytes := print_finish(*doc);
//     print_save(bytes, print_file_name("Statement", account, month));
//
// Blocks draw straight into the PDF; for something new on the page (a
// chart) add a block here, drawing with the pdf_ procedures, and call
// print_room first so it moves to a new page rather than running off this one.
// All of it is temporary storage.

Print_Doc :: struct {
    pdf:  Pdf_Document;
    kind: string;            // What the document is, in every page's header: "Transaction".
    generated: Timestamp;
    y: float;                // Top of the next block, points from the top of the page.
    pending_section: string; // Drawn with the section's first field.
    columns: [] Print_Column; // The table being drawn: its heading repeats on each new page.
}

// A column of a table. A width of 0 takes what the others leave.
Print_Column :: struct {
    title: string;
    width: float;
    right: bool;   // Aligned right, as amounts are.
}

PRINT_MARGIN       :: 56.0;    // Left and right, points (about 2 cm).
PRINT_CONTENT_TOP  :: 104.0;   // Below the header.
PRINT_FOOTER       :: 70.0;    // From the bottom of the page to the footer's rule.
PRINT_LABEL_WIDTH  :: 128.0;   // The label column of fields.

// On paper: dark text, quiet greys, and the app's colors deepened enough
// to read in print.
PRINT_TEXT      :: #run rgb(0x16191D);
PRINT_SECONDARY :: #run rgb(0x464D57);
PRINT_MUTED     :: #run rgb(0x6E7681);
PRINT_FAINT     :: #run rgb(0x9AA1AB);
PRINT_RULE      :: #run rgb(0xD9DDE2);
PRINT_HAIRLINE  :: #run rgb(0xECEEF1);
PRINT_POSITIVE  :: #run rgb(0x15804D);
PRINT_HELD      :: #run rgb(0x9A6200);

// Starts a document on its first page. `title` names the file in PDF
// readers' title bars.
print_begin :: (doc: *Print_Doc, kind: string, title: string) {
    doc.* = .{};
    doc.kind = kind;
    now := platform_local_time();
    doc.generated = .{utc = now.utc_seconds, offset = now.offset_minutes};
    pdf_begin(*doc.pdf, title, "Uppies");
    doc.pdf.created = doc.generated;
    print_new_page(doc);
}

print_new_page :: (doc: *Print_Doc) {
    pdf_add_page(*doc.pdf);
    doc.y = PRINT_CONTENT_TOP;

    // Header: the brand on the left, what this is on the right, a rule.
    p := *doc.pdf;
    MARK :: 22.0;
    top := 44.0;
    print_brand_mark(p, PRINT_MARGIN, top, MARK);
    pdf_text(p, PRINT_MARGIN + MARK + 8, top + 15.5, .BOLD, 13, "Uppies", PRINT_TEXT);
    kind := to_upper_temp(doc.kind);
    kw := pdf_measure(.BOLD, 8, kind, 0.8);
    pdf_text(p, p.width - PRINT_MARGIN - kw, top + 14.5, .BOLD, 8, kind, PRINT_MUTED, 0.8);
    pdf_line(p, PRINT_MARGIN, top + MARK + 12, p.width - PRINT_MARGIN, top + MARK + 12, 0.75, PRINT_RULE);

    if doc.columns.count draw_table_heading(doc);
}

// Makes sure the next `height` points fit on this page, starting a new
// one if they don't.
print_room :: (doc: *Print_Doc, height: float) {
    if doc.y + height > content_bottom(doc) && doc.y > PRINT_CONTENT_TOP print_new_page(doc);
}

print_content_width :: (doc: *Print_Doc) -> float {
    return doc.pdf.width - 2 * PRINT_MARGIN;
}

// The document's heading, wrapped over as many lines as it needs.
print_title :: (doc: *Print_Doc, text: string) {
    SIZE :: 20.0;
    LINE :: 25.0;
    for pdf_wrap(.BOLD, SIZE, text, print_content_width(doc)) {
        print_room(doc, LINE);
        pdf_text(*doc.pdf, PRINT_MARGIN, doc.y + 19, .BOLD, SIZE, it, PRINT_TEXT);
        doc.y += LINE;
    }
    doc.y += 4;
}

// A headline figure.
print_amount :: (doc: *Print_Doc, text: string, color: Color) {
    print_room(doc, 40);
    pdf_text(*doc.pdf, PRINT_MARGIN, doc.y + 30, .BOLD, 30, text, color);
    doc.y += 42;
}

// A line or two of supporting text under the title.
print_caption :: (doc: *Print_Doc, text: string) {
    for pdf_wrap(.REGULAR, 10.5, text, print_content_width(doc)) {
        print_room(doc, 15);
        pdf_text(*doc.pdf, PRINT_MARGIN, doc.y + 11, .REGULAR, 10.5, it, PRINT_SECONDARY);
        doc.y += 15;
    }
    doc.y += 6;
}

// Starts a section. Its heading is drawn with its first field, so a
// section with nothing in it doesn't appear at all.
print_section :: (doc: *Print_Doc, title: string) {
    doc.pending_section = title;
}

// A label and its value, the value wrapped to the width left. An empty
// value is left out, like the inspector does.
print_field :: (doc: *Print_Doc, label: string, value: string, mono := false, color: Color = 0) {
    if !value.count return;
    PAD  :: 6.5;
    LINE :: 14.0;
    font := ifx mono then Pdf_Font.MONO else .REGULAR;
    size := ifx mono then 9.5 else 10.5;
    value_x := PRINT_MARGIN + PRINT_LABEL_WIDTH;
    lines := pdf_wrap(font, size, value, print_content_width(doc) - PRINT_LABEL_WIDTH);
    if !lines.count return;

    section_height := ifx doc.pending_section.count then 36.0 else 0.0;
    print_room(doc, section_height + PAD * 2 + LINE);
    draw_pending_section(doc);

    top := doc.y + PAD;
    pdf_text(*doc.pdf, PRINT_MARGIN, top + 10, .REGULAR, 9.5, label, PRINT_MUTED);
    y := top;
    for lines {
        if y + LINE > content_bottom(doc) {
            // A very long value carries on at the top of the next page.
            print_new_page(doc);
            y = doc.y;
        }
        pdf_text(*doc.pdf, value_x, y + 10, font, size, it, ifx color then color else PRINT_TEXT);
        y += LINE;
    }
    doc.y = y + PAD;
    pdf_line(*doc.pdf, PRINT_MARGIN, doc.y, doc.pdf.width - PRINT_MARGIN, doc.y, 0.5, PRINT_HAIRLINE);
}

// A paragraph of small print.
print_note :: (doc: *Print_Doc, text: string) {
    doc.y += 8;
    for pdf_wrap(.REGULAR, 8.5, text, print_content_width(doc)) {
        print_room(doc, 12);
        pdf_text(*doc.pdf, PRINT_MARGIN, doc.y + 9, .REGULAR, 8.5, it, PRINT_MUTED);
        doc.y += 12;
    }
}

// Starts a table: its column headings, which repeat at the top of every
// page it flows onto, then a print_table_row for each row and
// print_table_end after the last.
print_table_begin :: (doc: *Print_Doc, columns: [] Print_Column) {
    section_height := ifx doc.pending_section.count then 36.0 else 0.0;
    print_room(doc, section_height + TABLE_HEADING + TABLE_PAD * 2 + TABLE_LINE);
    draw_pending_section(doc);
    doc.columns = columns;
    draw_table_heading(doc);
}

// A row, one cell for each column; text wraps within its column. `colors`
// are each cell's (0, or none given, for the usual). A total is bold with a
// rule above it.
print_table_row :: (doc: *Print_Doc, cells: [] string, colors: [] Color = .[], total := false) {
    font := ifx total then Pdf_Font.BOLD else .REGULAR;
    lines := NewArray(doc.columns.count, [] string,, temp);
    most := 1;
    for col, i: doc.columns {
        if i >= cells.count break;
        lines[i] = pdf_wrap(font, TABLE_SIZE, cells[i], cell_width(doc, i));
        most = max(most, lines[i].count);
    }
    height := TABLE_PAD * 2 + most * TABLE_LINE;
    print_room(doc, height);
    if total pdf_line(*doc.pdf, PRINT_MARGIN, doc.y, doc.pdf.width - PRINT_MARGIN, doc.y, 0.75, PRINT_RULE);

    x := PRINT_MARGIN;
    for col, i: doc.columns {
        w := column_width(doc, i);
        color := ifx i < colors.count && colors[i] then colors[i] else PRINT_TEXT;
        for lines[i] {
            tx := ifx col.right then x + cell_width(doc, i) - pdf_measure(font, TABLE_SIZE, it) else x;
            pdf_text(*doc.pdf, tx, doc.y + TABLE_PAD + 10 + it_index * TABLE_LINE, font, TABLE_SIZE, it, color);
        }
        x += w;
    }
    doc.y += height;
    if !total pdf_line(*doc.pdf, PRINT_MARGIN, doc.y, doc.pdf.width - PRINT_MARGIN, doc.y, 0.5, PRINT_HAIRLINE);
}

print_table_end :: (doc: *Print_Doc) {
    doc.columns = .[];
}

// Adds the footer to every page and returns the file.
print_finish :: (doc: *Print_Doc) -> string {
    p := *doc.pdf;
    generated := tprint("Generated % at % (UTC%)", format_date(ts_day(doc.generated)), format_time(doc.generated), format_utc_offset(doc.generated.offset));
    width := print_content_width(doc);
    for 0..p.pages.count - 1 {
        p.page = it;
        rule_y := p.height - PRINT_FOOTER;
        pdf_line(p, PRINT_MARGIN, rule_y, p.width - PRINT_MARGIN, rule_y, 0.75, PRINT_RULE);

        page := tprint("Page % of %", it + 1, p.pages.count);
        page_w := pdf_measure(.REGULAR, 8, page);
        pdf_text(p, p.width - PRINT_MARGIN - page_w, rule_y + 16, .REGULAR, 8, page, PRINT_MUTED);

        x := PRINT_MARGIN;
        x += pdf_text(p, x, rule_y + 16, .BOLD, 8, "Made with Uppies", PRINT_SECONDARY);
        pdf_text(p, x, rule_y + 16, .REGULAR, 8, pdf_fit(.REGULAR, 8, tprint(", a desktop app for Up. %.", generated), width - (x - PRINT_MARGIN) - page_w - 16), PRINT_MUTED);
        small := "Prepared from data provided by the Up API. Not a bank statement or an official record from Up.";
        pdf_text(p, PRINT_MARGIN, rule_y + 28, .REGULAR, 7, pdf_fit(.REGULAR, 7, small, width), PRINT_FAINT);
    }
    return pdf_finish(p);
}

// Asks where to save the PDF (the Save dialog) and writes it there, saying
// how it went in a toast.
print_save :: (bytes: string, suggested_name: string) {
    path, chosen := platform_save_file_dialog("Save as PDF", suggested_name, "PDF document", "pdf");
    if !chosen return;
    name := path_filename(path);
    if platform_write_file_atomic(path, cast([] u8) bytes) app_toast(.SUCCESS, tprint("Saved %.", name));
    else app_toast(.ERROR, tprint("Couldn't save %. If it's open in another app, close it and try again.", name));
}

// A file name from its parts, "Transaction - Coles - 2026-10-06.pdf",
// without the characters Windows doesn't allow in names.
print_file_name :: (parts: .. string) -> string {
    cleaned: [..] string;
    cleaned.allocator = temp;
    for part: parts {
        b: String_Builder;
        b.allocator = temp;
        space := true;   // Drops leading spaces, and runs of them.
        for cast([] u8) part {
            if it <= #char " " || it == #char "<" || it == #char ">" || it == #char ":" || it == #char "\"" || it == #char "/" || it == #char "\\" || it == #char "|" || it == #char "?" || it == #char "*" {
                if !space append(*b, #char " ");
                space = true;
            } else {
                append(*b, it);
                space = false;
            }
        }
        clean := trim_right(builder_to_string(*b,, temp), " .");
        if clean.count array_add(*cleaned, clean);
    }
    name := join(..cleaned, separator = " - ",, temp);
    // Long enough to be useful, short enough for any folder; never cut
    // inside a character.
    if name.count > 120 {
        i := 0;
        end := 0;
        while i < name.count && i <= 120 { end = i; next_code_point(name, *i); }
        name = trim_right(slice(name, 0, end), " .-");
    }
    return tprint("%.pdf", ifx name.count then name else "Uppies");
}

// "+11:00", "-03:30".
format_utc_offset :: (minutes: s32) -> string {
    o := abs(minutes);
    return tprint("%1%2:%3", ifx minutes < 0 then "-" else "+", pad2(o / 60), pad2(o % 60));
}

#scope_file

TABLE_HEADING :: 24.0;
TABLE_PAD     :: 5.5;
TABLE_LINE    :: 14.0;
TABLE_SIZE    :: 10.0;
TABLE_GAP     :: 12.0;   // Between one column's text and the next.

column_width :: (doc: *Print_Doc, index: int) -> float {
    w := doc.columns[index].width;
    if w > 0 return w;
    rest := print_content_width(doc);
    for doc.columns rest -= it.width;
    return max(rest, 0);
}

// Room for text in a column: all of it for the last, short of the gap for the rest.
cell_width :: (doc: *Print_Doc, index: int) -> float {
    w := column_width(doc, index);
    if index < doc.columns.count - 1 w -= TABLE_GAP;
    return max(w, 1);
}

draw_table_heading :: (doc: *Print_Doc) {
    x := PRINT_MARGIN;
    for col, i: doc.columns {
        title := to_upper_temp(col.title);
        tx := ifx col.right then x + cell_width(doc, i) - pdf_measure(.BOLD, 7.5, title, 0.6) else x;
        pdf_text(*doc.pdf, tx, doc.y + 16, .BOLD, 7.5, title, PRINT_MUTED, 0.6);
        x += column_width(doc, i);
    }
    doc.y += TABLE_HEADING;
    pdf_line(*doc.pdf, PRINT_MARGIN, doc.y, doc.pdf.width - PRINT_MARGIN, doc.y, 0.75, PRINT_RULE);
}

content_bottom :: (doc: *Print_Doc) -> float {
    return doc.pdf.height - PRINT_FOOTER - 18;
}

draw_pending_section :: (doc: *Print_Doc) {
    if !doc.pending_section.count return;
    doc.y += 18;
    pdf_text(*doc.pdf, PRINT_MARGIN, doc.y + 8, .BOLD, 8, to_upper_temp(doc.pending_section), PRINT_MUTED, 0.8);
    doc.y += 14;
    pdf_line(*doc.pdf, PRINT_MARGIN, doc.y, doc.pdf.width - PRINT_MARGIN, doc.y, 0.75, PRINT_RULE);
    doc.pending_section = "";
}

// The app icon (draw_brand_mark in app.jai) in PDF paths: a "U" whose right
// arm rises into an arrow, on a gradient plate. Glyph coordinates are the
// icon's, in which the plate is 224 units across.
print_brand_mark :: (p: *Pdf_Document, x: float, y: float, size: float) {
    pdf_rect_gradient(p, x, y, size, size, theme.brand_top, theme.brand_bottom, size * 0.26);
    k  := size / 224;
    ox := x + 61.5 * k;
    oy := y + 90.5 * k;
    stroke := 31 * k;

    // Left arm, the bowl (a half circle) and the right arm up to the arrow's tip.
    r := 37 * k;
    cx := ox + r;
    cy := oy + 56 * k;
    c := r * 0.5523;
    pdf_path_begin(p, stroke = theme.brand_glyph, width = stroke, round = true);
    pdf_move_to(p, ox, oy + 4 * k);
    pdf_line_to(p, ox, cy);
    pdf_curve_to(p, ox, cy + c, cx - c, cy + r, cx, cy + r);
    pdf_curve_to(p, cx + c, cy + r, cx + r, cy + c, cx + r, cy);
    pdf_line_to(p, ox + 74 * k, oy - 46 * k);
    // Arrowhead.
    pdf_move_to(p, ox + 47 * k, oy - 19 * k);
    pdf_line_to(p, ox + 74 * k, oy - 46 * k);
    pdf_line_to(p, ox + 101 * k, oy - 19 * k);
    pdf_path_end(p);
}
