// Number and money formatting. Money is always integer cents (the API's
// valueInBaseUnits): no floating point anywhere near a balance. Also UTF-8
// decoding, for the text drawing and the PDF writer.

MINUS_SIGN :: "−";   // A real minus: as wide as the plus, unlike a hyphen.

Sign_Display :: enum u8 {
    NEGATIVE;   // "−$5.00", "$5.00"
    ALWAYS;     // "−$5.00", "+$5.00"
    NONE;       // "$5.00" either way
    POSITIVE;   // "$5.00", "+$5.00": only money in marked
}

// "1,284,001"
// "640 bytes", "84 KB", "1.2 MB".
format_bytes :: (bytes: s64) -> string {
    if bytes < 1024 return tprint("% bytes", bytes);
    if bytes < 1024 * 1024 return tprint("% KB", (bytes + 512) / 1024);
    return tprint("% MB", formatFloat(bytes / (1024.0 * 1024.0), trailing_width = 1, zero_removal = .NO));
}

format_grouped :: (value: s64) -> string {
    negative := value < 0;
    v := ifx negative then -value else value;
    digits: [24] u8;
    n := 0;
    count := 0;
    while true {
        if count > 0 && count % 3 == 0 { digits[n] = #char ","; n += 1; }
        digits[n] = cast(u8) (#char "0" + v % 10);
        n += 1;
        count += 1;
        v /= 10;
        if v == 0 break;
    }
    builder: String_Builder;
    builder.allocator = temp;
    if negative append(*builder, MINUS_SIGN);
    for < 0..n - 1 append(*builder, digits[it]);
    return builder_to_string(*builder,, temp);
}

// "$1,234.56" with the sign handled per `sign`.
format_money :: (cents: s64, sign := Sign_Display.NEGATIVE) -> string {
    negative := cents < 0;
    v := ifx negative then -cents else cents;
    prefix := "";
    if negative && (sign == .NEGATIVE || sign == .ALWAYS) prefix = MINUS_SIGN;
    else if cents > 0 && (sign == .ALWAYS || sign == .POSITIVE) prefix = "+";
    return tprint("%$%.%", prefix, format_grouped(v / 100), pad2(v % 100));
}

// Whole dollars: "$1,235". Rounds half away from zero.
format_money_whole :: (cents: s64, sign := Sign_Display.NEGATIVE) -> string {
    negative := cents < 0;
    v := ifx negative then -cents else cents;
    v = (v + 50) / 100;
    prefix := "";
    if negative && v > 0 && (sign == .NEGATIVE || sign == .ALWAYS) prefix = MINUS_SIGN;
    else if !negative && v > 0 && (sign == .ALWAYS || sign == .POSITIVE) prefix = "+";
    return tprint("%$%", prefix, format_grouped(v));
}

// Short, for axis ticks and tight cells: "$950", "$1.2k", "$48k", "$1.3M".
format_money_compact :: (cents: s64) -> string {
    negative := cents < 0;
    v := cast(float64) (ifx negative then -cents else cents) / 100.0;
    prefix := ifx negative then MINUS_SIGN else "";
    // One decimal, dropped when it is zero: "$1.2k", "$4k".
    one_decimal :: (x: float64) -> string {
        tenths := cast(s64) (x * 10 + 0.5);
        if tenths % 10 == 0 return tprint("%", tenths / 10);
        return tprint("%.%", tenths / 10, tenths % 10);
    }
    if v < 1000       return tprint("%$%", prefix, cast(s64) (v + 0.5));
    if v < 10_000     return tprint("%$%k", prefix, one_decimal(v / 1000));
    if v < 1_000_000  return tprint("%$%k", prefix, cast(s64) (v / 1000 + 0.5));
    return tprint("%$%M", prefix, one_decimal(v / 1_000_000));
}

// "12.4%"
format_percent :: (fraction: float64, decimals := 1) -> string {
    return tprint("%%", formatFloat(fraction * 100, trailing_width = decimals, zero_removal = .NO), "%");
}

// Change from previous to current, as a signed percentage: "+12%", "−4%".
// Empty when there is nothing to compare with.
format_change_percent :: (current: s64, previous: s64) -> string {
    if previous == 0 return "";
    change := (cast(float64) current - cast(float64) previous) / abs(cast(float64) previous);
    pct := cast(s64) (abs(change) * 100 + 0.5);
    if pct == 0 return "0%";
    sign := ifx change < 0 then MINUS_SIGN else "+";
    // Ten times or more reads better as a multiple.
    if pct >= 1000 return tprint("×%", cast(s64) (cast(float64) current / abs(cast(float64) previous) + 0.5));
    return tprint("%%%", sign, pct, "%");
}

// Up writes foreign values with the currency's own decimals ("-12.50",
// "-1200"); show them as given, with the code: "USD 12.50".
format_foreign :: (currency: string, value: string) -> string {
    v := value;
    if v.count && v[0] == #char "-" advance(*v, 1);
    return tprint("% %", currency, v);
}

format_count :: (n: s64, singular: string, plural: string) -> string {
    return tprint("% %", format_grouped(n), ifx n == 1 then singular else plural);
}

// Decodes the UTF-8 code point at text[i.*] and moves i past it. Malformed
// bytes come out as U+FFFD.
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
