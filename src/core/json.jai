// JSON: a small, strict parser into a tree, and string escaping for writing.
//
// json_parse allocates every node and string with context.allocator; parse
// into a pool and drop the whole pool once the values you need are copied
// out. Lookups never fail loudly: a missing key or a type mismatch reads as
// null / "" / 0, which is what the API's many nullable fields want.

JSON_Kind :: enum u8 { NULL; BOOL; NUMBER; STRING; ARRAY; OBJECT; }

JSON :: struct {
    kind:    JSON_Kind;
    boolean: bool;
    is_integer: bool;
    integer: s64;        // Exact when the literal had no fraction or exponent.
    number:  float64;
    text:    string;     // STRING
    items:   [] JSON;    // ARRAY items, or OBJECT values
    keys:    [] string;  // OBJECT keys, parallel to items
}

JSON_NULL :: JSON.{};

json_parse :: (source: string) -> JSON, ok: bool, error: string {
    p: JSON_Parser;
    p.s = source;
    value: JSON;
    skip_ws(*p);
    ok := parse_value(*p, *value, 0);
    if ok {
        skip_ws(*p);
        if p.at != p.s.count fail(*p, "trailing characters");
    }
    if p.error return .{}, false, p.error;
    return value, true, "";
}

// Member of an object; null if absent or not an object.
json_get :: (node: *JSON, key: string) -> *JSON {
    if !node || node.kind != .OBJECT return null;
    for node.keys if it == key return *node.items[it_index];
    return null;
}

// Walks nested objects: json_at(resource, "attributes", "amount", "valueInBaseUnits").
json_at :: (node: *JSON, path: ..string) -> *JSON {
    n := node;
    for path {
        n = json_get(n, it);
        if !n return null;
    }
    return n;
}

json_is_null :: inline (node: *JSON) -> bool { return !node || node.kind == .NULL; }

json_string :: (node: *JSON) -> string {
    if !node || node.kind != .STRING return "";
    return node.text;
}

json_int :: (node: *JSON) -> s64 {
    if !node || node.kind != .NUMBER return 0;
    if node.is_integer return node.integer;
    return cast(s64) node.number;
}

json_bool :: (node: *JSON) -> bool {
    return node && node.kind == .BOOL && node.boolean;
}

json_array :: (node: *JSON) -> [] JSON {
    if !node || node.kind != .ARRAY return .[];
    return node.items;
}

// Escapes s for use inside a JSON string literal (without the quotes).
json_escape :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    for 0..s.count - 1 {
        c := s[it];
        if c == {
            case #char "\""; append(*builder, "\\\"");
            case #char "\\"; append(*builder, "\\\\");
            case #char "\n"; append(*builder, "\\n");
            case #char "\r"; append(*builder, "\\r");
            case #char "\t"; append(*builder, "\\t");
            case;
                if c < 0x20 print_to_builder(*builder, "\\u%", formatInt(c, base = 16, minimum_digits = 4));
                else append(*builder, c);
        }
    }
    return builder_to_string(*builder,, temp);
}

#scope_file

MAX_DEPTH :: 64;

JSON_Parser :: struct {
    s: string;
    at: int;
    error: string;
}

fail :: (p: *JSON_Parser, what: string) -> bool {
    if !p.error p.error = tprint("JSON: % at offset %", what, p.at);
    return false;
}

skip_ws :: inline (p: *JSON_Parser) {
    while p.at < p.s.count {
        c := p.s[p.at];
        if c != #char " " && c != #char "\n" && c != #char "\r" && c != #char "\t" break;
        p.at += 1;
    }
}

expect_word :: (p: *JSON_Parser, word: string) -> bool {
    if p.at + word.count > p.s.count return fail(p, "unexpected end");
    for 0..word.count - 1 if p.s[p.at + it] != word[it] return fail(p, "bad literal");
    p.at += word.count;
    return true;
}

parse_value :: (p: *JSON_Parser, out: *JSON, depth: int) -> bool {
    if depth > MAX_DEPTH return fail(p, "nested too deeply");
    if p.at >= p.s.count return fail(p, "unexpected end");
    c := p.s[p.at];
    if c == {
        case #char "{"; return parse_object(p, out, depth);
        case #char "["; return parse_array(p, out, depth);
        case #char "\"";
            out.kind = .STRING;
            text, ok := parse_string(p);
            out.text = text;
            return ok;
        case #char "t"; out.kind = .BOOL; out.boolean = true; return expect_word(p, "true");
        case #char "f"; out.kind = .BOOL; out.boolean = false; return expect_word(p, "false");
        case #char "n"; out.kind = .NULL; return expect_word(p, "null");
    }
    if c == #char "-" || (c >= #char "0" && c <= #char "9") return parse_number(p, out);
    return fail(p, "unexpected character");
}

parse_object :: (p: *JSON_Parser, out: *JSON, depth: int) -> bool {
    p.at += 1;   // {
    keys: [..] string;
    values: [..] JSON;
    keys.allocator = temp;
    values.allocator = temp;
    skip_ws(p);
    if p.at < p.s.count && p.s[p.at] == #char "}" {
        p.at += 1;
    } else {
        while true {
            skip_ws(p);
            if p.at >= p.s.count || p.s[p.at] != #char "\"" return fail(p, "expected a key");
            key, ok := parse_string(p);
            if !ok return false;
            skip_ws(p);
            if p.at >= p.s.count || p.s[p.at] != #char ":" return fail(p, "expected ':'");
            p.at += 1;
            skip_ws(p);
            value: JSON;
            if !parse_value(p, *value, depth + 1) return false;
            array_add(*keys, key);
            array_add(*values, value);
            skip_ws(p);
            if p.at >= p.s.count return fail(p, "unexpected end");
            if p.s[p.at] == #char "," { p.at += 1; continue; }
            if p.s[p.at] == #char "}" { p.at += 1; break; }
            return fail(p, "expected ',' or '}'");
        }
    }
    out.kind  = .OBJECT;
    out.keys  = array_copy(keys);
    out.items = array_copy(values);
    return true;
}

parse_array :: (p: *JSON_Parser, out: *JSON, depth: int) -> bool {
    p.at += 1;   // [
    values: [..] JSON;
    values.allocator = temp;
    skip_ws(p);
    if p.at < p.s.count && p.s[p.at] == #char "]" {
        p.at += 1;
    } else {
        while true {
            skip_ws(p);
            value: JSON;
            if !parse_value(p, *value, depth + 1) return false;
            array_add(*values, value);
            skip_ws(p);
            if p.at >= p.s.count return fail(p, "unexpected end");
            if p.s[p.at] == #char "," { p.at += 1; continue; }
            if p.s[p.at] == #char "]" { p.at += 1; break; }
            return fail(p, "expected ',' or ']'");
        }
    }
    out.kind  = .ARRAY;
    out.items = array_copy(values);
    return true;
}

parse_number :: (p: *JSON_Parser, out: *JSON) -> bool {
    start := p.at;
    negative := false;
    if p.s[p.at] == #char "-" { negative = true; p.at += 1; }
    integer: s64;
    digits := 0;
    while p.at < p.s.count && p.s[p.at] >= #char "0" && p.s[p.at] <= #char "9" {
        integer = integer * 10 + (p.s[p.at] - #char "0");
        p.at += 1;
        digits += 1;
    }
    if digits == 0 return fail(p, "bad number");
    is_integer := true;
    if p.at < p.s.count && p.s[p.at] == #char "." {
        is_integer = false;
        p.at += 1;
        while p.at < p.s.count && p.s[p.at] >= #char "0" && p.s[p.at] <= #char "9" p.at += 1;
    }
    if p.at < p.s.count && (p.s[p.at] == #char "e" || p.s[p.at] == #char "E") {
        is_integer = false;
        p.at += 1;
        if p.at < p.s.count && (p.s[p.at] == #char "+" || p.s[p.at] == #char "-") p.at += 1;
        while p.at < p.s.count && p.s[p.at] >= #char "0" && p.s[p.at] <= #char "9" p.at += 1;
    }
    out.kind = .NUMBER;
    out.is_integer = is_integer && digits <= 18;
    if out.is_integer {
        out.integer = ifx negative then -integer else integer;
        out.number  = cast(float64) out.integer;
    } else {
        text := slice(p.s, start, p.at - start);
        value, ok := string_to_float64(text);
        out.number  = value;
        out.integer = cast(s64) value;
    }
    return true;
}

parse_hex4 :: (p: *JSON_Parser) -> u32, bool {
    if p.at + 4 > p.s.count return 0, false;
    v: u32;
    for 0..3 {
        c := p.s[p.at + it];
        d: u32;
        if c >= #char "0" && c <= #char "9"      d = c - #char "0";
        else if c >= #char "a" && c <= #char "f" d = c - #char "a" + 10;
        else if c >= #char "A" && c <= #char "F" d = c - #char "A" + 10;
        else return 0, false;
        v = (v << 4) | d;
    }
    p.at += 4;
    return v, true;
}

append_utf8 :: (builder: *String_Builder, cp: u32) {
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

parse_string :: (p: *JSON_Parser) -> string, bool {
    p.at += 1;   // Opening quote.
    // Fast path: no escapes.
    start := p.at;
    while p.at < p.s.count {
        c := p.s[p.at];
        if c == #char "\"" {
            result := copy_string(slice(p.s, start, p.at - start));
            p.at += 1;
            return result, true;
        }
        if c == #char "\\" break;
        if c < 0x20 return "", fail(p, "control character in string");
        p.at += 1;
    }

    builder: String_Builder;
    builder.allocator = temp;
    append(*builder, slice(p.s, start, p.at - start));
    while p.at < p.s.count {
        c := p.s[p.at];
        if c == #char "\"" {
            p.at += 1;
            return builder_to_string(*builder), true;   // context.allocator
        }
        if c < 0x20 return "", fail(p, "control character in string");
        if c != #char "\\" {
            append(*builder, c);
            p.at += 1;
            continue;
        }
        p.at += 1;
        if p.at >= p.s.count break;
        e := p.s[p.at];
        p.at += 1;
        if e == {
            case #char "\""; append(*builder, #char "\"");
            case #char "\\"; append(*builder, #char "\\");
            case #char "/";  append(*builder, #char "/");
            case #char "b";  append(*builder, cast(u8) 8);
            case #char "f";  append(*builder, cast(u8) 12);
            case #char "n";  append(*builder, #char "\n");
            case #char "r";  append(*builder, #char "\r");
            case #char "t";  append(*builder, #char "\t");
            case #char "u";
                cp, ok := parse_hex4(p);
                if !ok return "", fail(p, "bad \\u escape");
                if cp >= 0xD800 && cp <= 0xDBFF {
                    // A surrogate pair: the low half must follow.
                    if p.at + 6 <= p.s.count && p.s[p.at] == #char "\\" && p.s[p.at + 1] == #char "u" {
                        p.at += 2;
                        low, ok2 := parse_hex4(p);
                        if ok2 && low >= 0xDC00 && low <= 0xDFFF cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        else cp = 0xFFFD;
                    } else {
                        cp = 0xFFFD;
                    }
                } else if cp >= 0xDC00 && cp <= 0xDFFF {
                    cp = 0xFFFD;
                }
                append_utf8(*builder, cp);
            case;
                return "", fail(p, "bad escape");
        }
    }
    return "", fail(p, "unterminated string");
}
