// Dates and times without a time zone database.
//
// The Up API writes every timestamp in RFC 3339 with the customer's local
// offset (+10:00 / +11:00 in Melbourne). A Timestamp keeps both the absolute
// instant (for ordering) and that offset (for display and for bucketing by
// the customer's own calendar day). Day numbers count days since 1970-01-01.

Timestamp :: struct {
    utc:    s64;   // Seconds since 1970-01-01T00:00:00Z.
    offset: s32;   // Minutes east of UTC, as written in the source.
}

Date :: struct {
    year:  s32;
    month: s32;   // 1..12
    day:   s32;   // 1..31
}

SECONDS_PER_DAY :: 86400;

// Howard Hinnant's civil calendar algorithms (proleptic Gregorian).
days_from_civil :: (y_in: int, m: int, d: int) -> s64 {
    y := y_in - (ifx m <= 2 then 1 else 0);
    era := (ifx y >= 0 then y else y - 399) / 400;
    yoe := y - era * 400;
    mp  := (m + 9) % 12;
    doy := (153 * mp + 2) / 5 + d - 1;
    doe := yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

civil_from_days :: (z_in: s64) -> Date {
    z := z_in + 719468;
    era := (ifx z >= 0 then z else z - 146096) / 146097;
    doe := z - era * 146097;
    yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y   := yoe + era * 400;
    doy := doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp  := (5 * doy + 2) / 153;
    d   := doy - (153 * mp + 2) / 5 + 1;
    m   := ifx mp < 10 then mp + 3 else mp - 9;
    if m <= 2 y += 1;
    return .{cast(s32) y, cast(s32) m, cast(s32) d};
}

// 0 = Monday .. 6 = Sunday.
weekday_from_days :: (day: s64) -> int {
    return cast(int) ((day % 7 + 7 + 3) % 7);   // 1970-01-01 was a Thursday.
}

floor_div :: inline (a: s64, b: s64) -> s64 {
    q := a / b;
    if (a % b != 0) && ((a < 0) != (b < 0)) q -= 1;
    return q;
}

ts_local_seconds :: inline (t: Timestamp) -> s64 { return t.utc + t.offset * 60; }
ts_day           :: inline (t: Timestamp) -> s64 { return floor_div(ts_local_seconds(t), SECONDS_PER_DAY); }

// Month keys count months since year 0: easy arithmetic across years.
month_key :: inline (year: int, month: int) -> s32 { return cast(s32) (year * 12 + month - 1); }
month_key_from_day :: (day: s64) -> s32 {
    d := civil_from_days(day);
    return month_key(d.year, d.month);
}
month_key_year  :: inline (key: int) -> s32 { return cast(s32) (key / 12); }
month_key_month :: inline (key: int) -> s32 { return cast(s32) (key % 12 + 1); }
first_day_of_month :: (key: int) -> s64 { return days_from_civil(month_key_year(key), month_key_month(key), 1); }
days_in_month :: (key: int) -> s64 { return first_day_of_month(key + 1) - first_day_of_month(key); }

MONTH_SHORT :: string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
MONTH_LONG  :: string.["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
WEEKDAY_SHORT :: string.["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
WEEKDAY_LONG  :: string.["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

// "2024-08-05T05:16:50+10:00", "2024-08-05T05:16:50.123Z". Returns false on
// anything else.
parse_rfc3339 :: (s: string) -> Timestamp, bool {
    t: Timestamp;
    if s.count < 19 return t, false;
    num :: (s: string, start: int, count: int) -> int, bool {
        v := 0;
        for start..start + count - 1 {
            c := s[it];
            if c < #char "0" || c > #char "9" return 0, false;
            v = v * 10 + (c - #char "0");
        }
        return v, true;
    }
    year,   ok1 := num(s, 0, 4);
    month,  ok2 := num(s, 5, 2);
    day,    ok3 := num(s, 8, 2);
    hour,   ok4 := num(s, 11, 2);
    minute, ok5 := num(s, 14, 2);
    second, ok6 := num(s, 17, 2);
    if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) return t, false;
    if month < 1 || month > 12 || day < 1 || day > 31 return t, false;

    i := 19;
    if i < s.count && s[i] == #char "." {   // Fractional seconds: ignored.
        i += 1;
        while i < s.count && s[i] >= #char "0" && s[i] <= #char "9" i += 1;
    }
    offset := 0;
    if i < s.count {
        c := s[i];
        if c == #char "Z" || c == #char "z" {
            offset = 0;
        } else if (c == #char "+" || c == #char "-") && i + 6 <= s.count {
            oh, okh := num(s, i + 1, 2);
            om, okm := num(s, i + 4, 2);
            if !okh || !okm return t, false;
            offset = oh * 60 + om;
            if c == #char "-" offset = -offset;
        } else {
            return t, false;
        }
    }
    local := days_from_civil(year, month, day) * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second;
    t.utc = local - offset * 60;
    t.offset = cast(s32) offset;
    return t, true;
}

// For API filters: always UTC with a Z, so nothing needs escaping but ':'.
format_rfc3339_utc :: (utc: s64) -> string {
    day := floor_div(utc, SECONDS_PER_DAY);
    secs := utc - day * SECONDS_PER_DAY;
    d := civil_from_days(day);
    return tprint("%-%-%T%:%:%Z", d.year, pad2(d.month), pad2(d.day), pad2(secs / 3600), pad2((secs / 60) % 60), pad2(secs % 60));
}

pad2 :: (v: int) -> string {
    return tprint("%", formatInt(v, minimum_digits = 2));
}

// "6 Oct 2026"
format_date :: (day: s64) -> string {
    d := civil_from_days(day);
    return tprint("% % %", d.day, MONTH_SHORT[d.month - 1], d.year);
}

// "2026-10-06"
format_date_iso :: (day: s64) -> string {
    d := civil_from_days(day);
    return tprint("%-%-%", d.year, pad2(d.month), pad2(d.day));
}

// "06 Oct" (fixed width, for table columns)
format_date_column :: (day: s64) -> string {
    d := civil_from_days(day);
    return tprint("% %", pad2(d.day), MONTH_SHORT[d.month - 1]);
}

// "06 Oct" this year, "15 Dec '25" otherwise: short, but never ambiguous.
format_date_short :: (day: s64, today: s64) -> string {
    d := civil_from_days(day);
    if civil_from_days(today).year == d.year return tprint("% %", pad2(d.day), MONTH_SHORT[d.month - 1]);
    return tprint("% % '%", pad2(d.day), MONTH_SHORT[d.month - 1], pad2(d.year % 100));
}

// "Tue 6 Oct" or "Tue 6 Oct 2025" when not this year.
format_weekday_date :: (day: s64, today: s64) -> string {
    d := civil_from_days(day);
    w := WEEKDAY_SHORT[weekday_from_days(day)];
    if civil_from_days(today).year == d.year return tprint("% % %", w, d.day, MONTH_SHORT[d.month - 1]);
    return tprint("% % % %", w, d.day, MONTH_SHORT[d.month - 1], d.year);
}

// "Tuesday 6 October 2026": for print, where there is room to spell it out.
format_date_long :: (day: s64) -> string {
    d := civil_from_days(day);
    return tprint("% % % %", WEEKDAY_LONG[weekday_from_days(day)], d.day, MONTH_LONG[d.month - 1], d.year);
}

// "Oct 2026"
format_month :: (key: int) -> string {
    return tprint("% %", MONTH_SHORT[month_key_month(key) - 1], month_key_year(key));
}

// "14:02" in the timestamp's own offset.
format_time :: (t: Timestamp) -> string {
    secs := ts_local_seconds(t) - ts_day(t) * SECONDS_PER_DAY;
    return tprint("%:%", pad2(secs / 3600), pad2((secs / 60) % 60));
}

format_time_seconds :: (t: Timestamp) -> string {
    secs := ts_local_seconds(t) - ts_day(t) * SECONDS_PER_DAY;
    return tprint("%:%:%", pad2(secs / 3600), pad2((secs / 60) % 60), pad2(secs % 60));
}

// "2026-10-06 14:02:11 +11:00": the precise form, for detail views.
format_timestamp_full :: (t: Timestamp) -> string {
    d := civil_from_days(ts_day(t));
    sign := ifx t.offset < 0 then "-" else "+";
    o := abs(t.offset);
    return tprint("%-%-% % %%:%", d.year, pad2(d.month), pad2(d.day), format_time_seconds(t), sign, pad2(o / 60), pad2(o % 60));
}

// "just now", "4m ago", "3h ago", "2d ago".
format_relative :: (seconds_ago: s64) -> string {
    s := max(seconds_ago, 0);
    if s < 45     return "just now";
    if s < 3600   return tprint("%m ago", max(s / 60, 1));
    if s < 86400  return tprint("%h ago", s / 3600);
    return tprint("%d ago", s / 86400);
}

// A coarse length of time: "12 min", "5 hours", "6 days".
format_span :: (seconds: s64) -> string {
    s := max(seconds, 0);
    if s < 3600 return tprint("% min", max((s + 30) / 60, 1));
    if s < 86400 - 1800 { h := (s + 1800) / 3600; return tprint("% hour%", h, ifx h == 1 then "" else "s"); }
    d := max((s + 43200) / 86400, 1);
    return tprint("% day%", d, ifx d == 1 then "" else "s");
}

// "45s", "3m 05s", "1h 02m".
format_duration :: (seconds: s64) -> string {
    s := max(seconds, 0);
    if s < 60   return tprint("%s", s);
    if s < 3600 return tprint("%m %s", s / 60, pad2(s % 60));
    return tprint("%h %m", s / 3600, pad2((s / 60) % 60));
}
