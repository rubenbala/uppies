// Single-line text input: caret and selection, word-wise movement (Ctrl),
// clipboard, mouse placement, drag and double-click selection, and a masked
// mode for secrets. Only the focused field has editing state (in ui), so
// any number of fields cost nothing while idle. The caret blinks by asking
// for a frame at each blink rather than rendering continuously.

Text_Input_Flags :: enum_flags u8 {
    PASSWORD;    // Shows bullets; copying is disabled.
    MONO;        // Monospace: identifiers, URLs, tokens.
    SEARCH;      // A magnifier on the left; Escape clears.
    CLEARABLE;   // A clear button when not empty.
}

ui_text_input :: (label: string, r: Rect, buffer: *Text_Buffer, placeholder := "", flags: Text_Input_Flags = 0, max_length := -1) -> changed: bool, submitted: bool {
    id := ui_id(label);
    w := ui_widget(id);
    io := ui_interact(id, r);
    focused := ui_focusable(id);
    ui_update_focus(w, id);
    if io.hovered ui.cursor = .TEXT;
    ui_animate(*w.hover, ifx io.hovered then 1.0 else 0.0, 22);

    font := ifx flags & .MONO then fonts.mono else fonts.regular;
    size := px(theme.font_size_body);
    limit := ifx max_length > 0 then min(max_length, buffer.data.count) else buffer.data.count;

    b := snap(r);
    inner := rect_inset_xy(b, px(9), 0);
    if flags & .SEARCH cut_left(*inner, px(18));
    clear_r: Rect;
    has_clear := (flags & (.CLEARABLE | .SEARCH)) && buffer.count > 0;
    if has_clear clear_r = cut_right(*inner, px(18));

    changed, submitted := false, false;
    text := buffer_string(buffer);

    // The clear button sits inside the field, so check it first.
    clear_clicked := false;
    if has_clear {
        cid := ui_id_combine(id, 0xC1EA);
        cw := ui_widget(cid);
        cio := ui_interact(cid, clear_r);
        if cio.hovered ui.cursor = .HAND;
        ui_animate(*cw.hover, ifx cio.hovered then 1.0 else 0.0, 22);
        if cio.clicked clear_clicked = true;
        if cio.pressed || cio.held { io.pressed = false; io.held = false; }
    }

    if io.pressed {
        if !focused {
            ui_take_focus(id);
            focused = true;
            w.t = 1;   // Gained by mouse: don't select all.
        }
        ui.focus_claimed = true;
        ui.edit_dragging = true;
        index := index_at_x(font, size, display_of(text, flags), text, flags, input.mouse_x - (inner.x - ui.edit_scroll));
        if ui.click_count >= 2 {
            ui.edit_anchor, ui.edit_cursor = word_bounds(text, index);
        } else {
            ui.edit_cursor = index;
            if !shift_down() ui.edit_anchor = index;
        }
        ui.edit_blink = ui.time;
    }

    if focused {
        ui.text_focus = true;
        if w.t == 0 {
            // Just gained focus from the keyboard: select everything.
            w.t = 1;
            ui.edit_anchor = 0;
            ui.edit_cursor = buffer.count;
            ui.edit_scroll = 0;
            ui.edit_blink = ui.time;
        }
        ui.edit_cursor = clamp(ui.edit_cursor, 0, buffer.count);
        ui.edit_anchor = clamp(ui.edit_anchor, 0, buffer.count);

        if ui.edit_dragging && ui.active == id && input.mouse_down[Mouse_Button.LEFT] && ui.click_count < 2 {
            ui.edit_cursor = index_at_x(font, size, display_of(text, flags), text, flags, input.mouse_x - (inner.x - ui.edit_scroll));
        }
        if !input.mouse_down[Mouse_Button.LEFT] ui.edit_dragging = false;

        if clear_clicked {
            buffer.count = 0;
            ui.edit_cursor, ui.edit_anchor = 0, 0;
            changed = true;
        }

        sel_lo := min(ui.edit_cursor, ui.edit_anchor);
        sel_hi := max(ui.edit_cursor, ui.edit_anchor);
        has_selection := sel_hi > sel_lo;
        ctrl := ctrl_down();
        shift := shift_down();
        edited := false;

        delete_range :: (buffer: *Text_Buffer, lo: s32, hi: s32) {
            if hi <= lo return;
            move_bytes(buffer.data.data + lo, buffer.data.data + hi, buffer.count - hi);
            buffer.count -= hi - lo;
        }
        insert :: (buffer: *Text_Buffer, at: s32, s: string, limit: int) -> s32 {
            n := cast(s32) min(s.count, limit - buffer.count);
            // Never split a UTF-8 sequence at the limit.
            while n > 0 && n < s.count && (s[n] & 0xC0) == 0x80 n -= 1;
            if n <= 0 return 0;
            move_bytes(buffer.data.data + at + n, buffer.data.data + at, buffer.count - at);
            memcpy(buffer.data.data + at, s.data, n);
            buffer.count += n;
            return n;
        }
        replace_selection :: (buffer: *Text_Buffer, s: string, limit: int) #expand {
            lo := min(ui.edit_cursor, ui.edit_anchor);
            hi := max(ui.edit_cursor, ui.edit_anchor);
            delete_range(buffer, lo, hi);
            n := insert(buffer, lo, s, limit);
            ui.edit_cursor = lo + n;
            ui.edit_anchor = ui.edit_cursor;
            `edited = true;
        }

        // Typed characters.
        if input.text.count && !ctrl {
            builder: String_Builder;
            builder.allocator = temp;
            for cp: input.text append_code_point(*builder, cp);
            replace_selection(buffer, builder_to_string(*builder,, temp), limit);
            input.text.count = 0;
        }

        if key_pressed(.BACKSPACE) {
            if has_selection replace_selection(buffer, "", limit);
            else if ui.edit_cursor > 0 {
                start := ifx ctrl then word_left(buffer_string(buffer), ui.edit_cursor) else prev_boundary(buffer_string(buffer), ui.edit_cursor);
                delete_range(buffer, start, ui.edit_cursor);
                ui.edit_cursor = start;
                ui.edit_anchor = start;
                edited = true;
            }
        }
        if key_pressed(.DELETE) {
            if has_selection replace_selection(buffer, "", limit);
            else if ui.edit_cursor < buffer.count {
                finish := ifx ctrl then word_right(buffer_string(buffer), ui.edit_cursor) else next_boundary(buffer_string(buffer), ui.edit_cursor);
                delete_range(buffer, ui.edit_cursor, finish);
                edited = true;
            }
        }
        move :: (to: s32, shift: bool) #expand {
            ui.edit_cursor = to;
            if !shift ui.edit_anchor = to;
            ui.edit_blink = ui.time;
        }
        current := buffer_string(buffer);
        if key_pressed(.LEFT) {
            if has_selection && !shift move(sel_lo, false);
            else move(ifx ctrl then word_left(current, ui.edit_cursor) else prev_boundary(current, ui.edit_cursor), shift);
        }
        if key_pressed(.RIGHT) {
            if has_selection && !shift move(sel_hi, false);
            else move(ifx ctrl then word_right(current, ui.edit_cursor) else next_boundary(current, ui.edit_cursor), shift);
        }
        if key_pressed(.HOME) move(0, shift);
        if key_pressed(.END)  move(buffer.count, shift);

        if ctrl {
            if letter_pressed(#char "A") { ui.edit_anchor = 0; ui.edit_cursor = buffer.count; }
            if letter_pressed(#char "C") && has_selection && !(flags & .PASSWORD) platform_clipboard_set(slice(buffer_string(buffer), sel_lo, sel_hi - sel_lo));
            if letter_pressed(#char "X") && has_selection && !(flags & .PASSWORD) {
                platform_clipboard_set(slice(buffer_string(buffer), sel_lo, sel_hi - sel_lo));
                replace_selection(buffer, "", limit);
            }
            if letter_pressed(#char "V") {
                pasted := platform_clipboard_get();
                // One line: drop line breaks and other control characters.
                clean: String_Builder;
                clean.allocator = temp;
                for 0..pasted.count - 1 {
                    c := pasted[it];
                    if c >= 0x20 && c != 0x7F append(*clean, c);
                }
                replace_selection(buffer, builder_to_string(*clean,, temp), limit);
            }
            // Keep Ctrl+letter from reaching global shortcuts.
            for c: "ACXV" input.key_pressed[c] = false;
        }

        if key_pressed(.ENTER) {
            submitted = true;
            input.key_pressed[Key.ENTER] = false;
        }
        if key_pressed(.ESCAPE) {
            input.key_pressed[Key.ESCAPE] = false;
            if (flags & (.SEARCH | .CLEARABLE)) && buffer.count {
                buffer.count = 0;
                ui.edit_cursor, ui.edit_anchor = 0, 0;
                edited = true;
            } else {
                ui.focus = 0;
            }
        }
        // Editing keys are this field's alone.
        for k: Key.[.LEFT, .RIGHT, .HOME, .END, .BACKSPACE, .DELETE, .UP, .DOWN, .SPACE] input.key_pressed[k] = false;

        if edited {
            changed = true;
            ui.edit_blink = ui.time;
        }
    } else {
        w.t = 0;
        if clear_clicked { buffer.count = 0; changed = true; }
    }

    // Drawing.
    radius := px(theme.radius_control);
    border := ifx focused then theme.accent else color_lerp(theme.border, theme.border_strong, w.hover);
    draw_rect_outline(b, ifx focused then theme.chrome else color_lerp(theme.raised, theme.hover, w.hover * 0.5), border, hairline(), radius);
    ui_focus_ring(b, w.focus * 0.0, radius);   // The accent border already shows focus.
    if flags & .SEARCH draw_icon(.SEARCH, b.x + px(15), b.y + b.h * 0.5, px(12), ifx focused then theme.text_secondary else theme.text_muted);
    if has_clear {
        cw := ui_widget(ui_id_combine(id, 0xC1EA));
        draw_icon_in(.CLOSE, clear_r, px(9), color_lerp(theme.text_muted, theme.text, cw.hover));
    }

    text = buffer_string(buffer);
    shown := display_of(text, flags);
    push_clip(rect(inner.x, b.y, inner.w, b.h));
    baseline := text_baseline_in(font, size, inner);
    if !text.count {
        if placeholder.count draw_text_fit(fonts.regular, size, inner, placeholder, theme.text_faint);
    }
    scroll := 0.0;
    if focused {
        caret_x := measure_text(font, size, slice(shown, 0, display_index(text, ui.edit_cursor, flags)));
        if caret_x - ui.edit_scroll > inner.w - px(2) ui.edit_scroll = caret_x - inner.w + px(2);
        if caret_x - ui.edit_scroll < 0 ui.edit_scroll = caret_x;
        ui.edit_scroll = max(ui.edit_scroll, 0);
        scroll = ui.edit_scroll;

        lo := min(ui.edit_cursor, ui.edit_anchor);
        hi := max(ui.edit_cursor, ui.edit_anchor);
        if hi > lo {
            x0 := measure_text(font, size, slice(shown, 0, display_index(text, lo, flags)));
            x1 := measure_text(font, size, slice(shown, 0, display_index(text, hi, flags)));
            draw_rect(rect(inner.x - scroll + x0, b.y + px(5), x1 - x0, b.h - px(10)), theme.accent_soft);
        }
        draw_text(font, size, inner.x - scroll, baseline, shown, theme.text);

        // Caret: solid right after input, then blinking.
        BLINK :: 0.53;
        phase := (ui.time - ui.edit_blink) / BLINK;
        on := (cast(s64) phase) % 2 == 0;
        ui_wake_at(ui.edit_blink + (floor(phase) + 1) * BLINK);
        if on && hi == lo draw_rect(snap(rect(inner.x - scroll + caret_x, b.y + px(6), px(1.5), b.h - px(12))), theme.accent);
    } else if text.count {
        draw_text(font, size, inner.x, baseline, fit_text(font, size, shown, inner.w), theme.text);
    }
    pop_clip();
    return changed, submitted;
}

#scope_file

// memcpy for overlapping ranges.
move_bytes :: (dst: *u8, src: *u8, count: int) {
    if count <= 0 || dst == src return;
    if dst < src {
        for i: 0..count - 1 dst[i] = src[i];
    } else {
        for < i: 0..count - 1 dst[i] = src[i];
    }
}

BULLET :: "•";

// What is drawn: the text, or a bullet per code point.
display_of :: (text: string, flags: Text_Input_Flags) -> string {
    if !(flags & .PASSWORD) return text;
    n := 0;
    i := 0;
    while i < text.count { next_code_point(text, *i); n += 1; }
    builder: String_Builder;
    builder.allocator = temp;
    for 1..n append(*builder, BULLET);
    return builder_to_string(*builder,, temp);
}

// Byte index in the text -> byte index in what is drawn.
display_index :: (text: string, index: s32, flags: Text_Input_Flags) -> int {
    if !(flags & .PASSWORD) return index;
    n := 0;
    i := 0;
    while i < index && i < text.count { next_code_point(text, *i); n += 1; }
    return n * BULLET.count;
}

// The boundary nearest to x (pixels from the text's start).
index_at_x :: (font: *Font, size: float, shown: string, text: string, flags: Text_Input_Flags, x: float) -> s32 {
    best: s32 = 0;
    best_d := abs(x);
    i := 0;
    while i < text.count {
        next_code_point(text, *i);
        w := measure_text(font, size, slice(shown, 0, display_index(text, cast(s32) i, flags)));
        d := abs(x - w);
        if d < best_d { best_d = d; best = cast(s32) i; }
    }
    return best;
}

prev_boundary :: (s: string, index: s32) -> s32 {
    i := index - 1;
    while i > 0 && (s[i] & 0xC0) == 0x80 i -= 1;
    return max(i, 0);
}

next_boundary :: (s: string, index: s32) -> s32 {
    if index >= s.count return cast(s32) s.count;
    i := index + 1;
    while i < s.count && (s[i] & 0xC0) == 0x80 i += 1;
    return i;
}

is_word_byte :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "_" || c >= 0x80;
}

word_left :: (s: string, index: s32) -> s32 {
    i := index;
    while i > 0 && !is_word_byte(s[i - 1]) i -= 1;
    while i > 0 && is_word_byte(s[i - 1]) i -= 1;
    return i;
}

word_right :: (s: string, index: s32) -> s32 {
    i := index;
    while i < s.count && !is_word_byte(s[i]) i += 1;
    while i < s.count && is_word_byte(s[i]) i += 1;
    return i;
}

word_bounds :: (s: string, index: s32) -> s32, s32 {
    lo := index;
    hi := index;
    while lo > 0 && is_word_byte(s[lo - 1]) lo -= 1;
    while hi < s.count && is_word_byte(s[hi]) hi += 1;
    return lo, hi;
}

append_code_point :: (builder: *String_Builder, cp: u32) {
    if cp < 0x80 {
        append(builder, cast(u8) cp);
    } else if cp < 0x800 {
        append(builder, cast(u8) (0xC0 | (cp >> 6)));
        append(builder, cast(u8) (0x80 | (cp & 0x3F)));
    } else if cp < 0x10000 {
        append(builder, cast(u8) (0xE0 | (cp >> 12)));
        append(builder, cast(u8) (0x80 | ((cp >> 6) & 0x3F)));
        append(builder, cast(u8) (0x80 | (cp & 0x3F)));
    } else {
        append(builder, cast(u8) (0xF0 | (cp >> 18)));
        append(builder, cast(u8) (0x80 | ((cp >> 12) & 0x3F)));
        append(builder, cast(u8) (0x80 | ((cp >> 6) & 0x3F)));
        append(builder, cast(u8) (0x80 | (cp & 0x3F)));
    }
}
