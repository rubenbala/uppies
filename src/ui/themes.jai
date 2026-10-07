// Themes: the UI's colors, from text files.
//
// A theme is a TOML file (the subset below), so any editor highlights it:
//
//     name = "Uppies Dark"
//
//     [surface]
//     background = "#0B0D10"     # A comment runs to the end of the line.
//     shadow     = "#00000096"   # #RRGGBBAA: with an alpha.
//
// A key is its section and name, "surface.background" (which can also be
// written that way, outside any section). Colors a theme leaves out keep
// Uppies Dark's, so a theme can change just the accent. Strings are in
// double or single quotes, without escapes.
//
// The built-in themes are themes/*.toml at the repo root, embedded at build
// time. The user's own are *.toml files in a folder the app chooses (beside
// the settings); one with a built-in's file name replaces it.

Theme_Entry :: struct {
    id:      string;   // The file name without .toml; the settings keep it.
    name:    string;
    colors:  Theme;
    dark:    bool;     // A dark background: the window's title bar follows.
    builtin: bool;
    problem: string;   // The first thing wrong with the file, if anything.
}

themes: [..] Theme_Entry;
theme_current: int;   // Index into themes.

DEFAULT_THEME :: "uppies-dark";

BUILTIN_THEMES :: struct { id: string; text: string; }.[
    .{"uppies-dark",      #run embed_theme("uppies-dark")},
    .{"uppies-light",     #run embed_theme("uppies-light")},
    .{"nord",             #run embed_theme("nord")},
    .{"dracula",          #run embed_theme("dracula")},
    .{"solarized-light",  #run embed_theme("solarized-light")},
    .{"catppuccin-latte", #run embed_theme("catppuccin-latte")},
];

// Each key a theme file can set, and the Theme member it colors.
THEME_KEYS :: struct { key: string; member: string; }.[
    .{"surface.background",    "background"},
    .{"surface.chrome",        "chrome"},
    .{"surface.panel",         "panel"},
    .{"surface.panel_header",  "panel_header"},
    .{"surface.raised",        "raised"},
    .{"surface.hover",         "hover"},
    .{"surface.active",        "active"},
    .{"surface.border",        "border"},
    .{"surface.border_strong", "border_strong"},
    .{"surface.divider",       "divider"},
    .{"surface.grid",          "grid"},
    .{"surface.shadow",        "shadow"},
    .{"surface.scrim",         "scrim"},
    .{"text.primary",          "text"},
    .{"text.secondary",        "text_secondary"},
    .{"text.muted",            "text_muted"},
    .{"text.faint",            "text_faint"},
    .{"accent.base",           "accent"},
    .{"accent.hover",          "accent_hover"},
    .{"accent.pressed",        "accent_pressed"},
    .{"accent.soft",           "accent_soft"},
    .{"accent.wash",           "accent_wash"},
    .{"accent.text",           "on_accent"},
    .{"status.positive",       "positive"},
    .{"status.held",           "held"},
    .{"status.danger",         "danger"},
    .{"status.danger_hover",   "danger_hover"},
    .{"status.info",           "info"},
    .{"chart.out",             "chart_out"},
    .{"chart.in",              "chart_in"},
    .{"chart.line",            "chart_line"},
    .{"category.good_life",    "category_good_life"},
    .{"category.personal",     "category_personal"},
    .{"category.home",         "category_home"},
    .{"category.transport",    "category_transport"},
    .{"category.other",        "uncategorised"},
];

// The built-in themes, then the *.toml files in user_dir ("" for none).
// theme_current stays on the same theme, if it's still there.
themes_load :: (user_dir: string) {
    current := ifx themes.count then copy_string(themes[theme_current].id,, temp) else DEFAULT_THEME;
    defer theme_current = max(theme_find(current), max(theme_find(DEFAULT_THEME), 0));
    for themes if !it.builtin { free(it.id); free(it.name); free(it.problem); }
    array_reset_keeping_memory(*themes);
    for BUILTIN_THEMES theme_add(it.id, it.text, true);
    if !user_dir.count || !is_directory(user_dir) return;

    files := file_list(user_dir);
    defer { for files free(it); array_free(files); }
    quick_sort(files, compare_strings);   // A stable order for the list.
    for files {
        extension, found := path_extension(it);
        if !found || to_lower_temp(extension) != "toml" continue;
        text, ok := read_entire_file(it,, temp);
        if !ok continue;
        theme_add(path_strip_extension(path_filename(it)), text, false);
    }
}

// The index of the theme with this id, or -1.
theme_find :: (id: string) -> int {
    for themes if it.id == id return it_index;
    return -1;
}

// Switches to a theme (an unknown id gives the default), fading the colors
// over unless `instant`. Returns whether the id was found.
theme_select :: (id: string, instant := false) -> bool {
    index := theme_find(id);
    found := index >= 0;
    if !found index = max(theme_find(DEFAULT_THEME), 0);
    theme_current = index;
    fade.from = theme;
    fade.t = ifx instant then 1.0 else 0.0;
    if instant theme = themes[index].colors;
    platform_set_dark_appearance(themes[index].dark);
    return found;
}

// Steps a theme change's fade; call once a frame, before anything draws.
theme_update :: () {
    if fade.t >= 1 return;
    fade.t = ifx ui.motion > 0 then min(fade.t + ui.dt * ui.motion / FADE_SECONDS, 1.0) else 1.0;
    to := *themes[theme_current].colors;
    e := ease_out_cubic(fade.t);
    for type_info(Theme).members {
        if it.type != cast(*Type_Info) type_info(Color) continue;
        from := cast(*Color) (cast(*u8) *fade.from + it.offset_in_bytes);
        target := cast(*Color) (cast(*u8) to + it.offset_in_bytes);
        (cast(*Color) (cast(*u8) *theme + it.offset_in_bytes)).* = color_lerp(from.*, target.*, e);
    }
    if fade.t < 1 ui.animating = true;
}

// Reads a theme over `colors`, which keeps what the text leaves out.
// Returns the theme's name and the first problem (empty if none), both
// pointing into `text` or in temporary storage.
theme_parse :: (text_in: string, colors: *Theme) -> name: string, problem: string {
    text := text_in;
    if text.count >= 3 && text[0] == 0xEF && text[1] == 0xBB && text[2] == 0xBF advance(*text, 3);   // UTF-8 BOM.
    name, problem: string;
    section: string;
    for line, line_index: split(text, "\n",, temp) {
        message := parse_line(trim(strip_comment(line)), *section, colors, *name);
        if message.count && !problem.count problem = tprint("line %: %", line_index + 1, message);
    }
    return name, problem;
}

// The color member a theme key sets, or null.
theme_color_for_key :: (colors: *Theme, key: string) -> *Color {
    for THEME_KEYS {
        if it.key != key continue;
        for member: type_info(Theme).members {
            if member.name == it.member && member.type == cast(*Type_Info) type_info(Color) return cast(*Color) (cast(*u8) colors + member.offset_in_bytes);
        }
    }
    return null;
}

// "#RRGGBB" or "#RRGGBBAA".
parse_hex_color :: (s: string) -> Color, bool {
    if (s.count != 7 && s.count != 9) || s[0] != #char "#" return 0, false;
    value: u32;
    for i: 1..s.count - 1 {
        c := s[i];
        digit: u32;
        if c >= #char "0" && c <= #char "9"      digit = c - #char "0";
        else if c >= #char "a" && c <= #char "f" digit = c - #char "a" + 10;
        else if c >= #char "A" && c <= #char "F" digit = c - #char "A" + 10;
        else return 0, false;
        value = (value << 4) | digit;
    }
    if s.count == 7 return rgb(value), true;
    return rgba(value >> 8, cast(u8) (value & 0xFF)), true;
}

#scope_file

FADE_SECONDS :: 0.3;

Theme_Fade :: struct {
    from: Theme;
    t: float = 1;
}
fade: Theme_Fade;

theme_add :: (id: string, text: string, builtin: bool) {
    entry: Theme_Entry;
    name, problem := theme_parse(text, *entry.colors);
    if !name.count name = id;
    entry.builtin = builtin;
    entry.dark = color_is_dark(entry.colors.background);
    if builtin {
        entry.id = id;
        entry.name = name;   // Points into the embedded text.
        entry.problem = problem;
    } else {
        entry.id = copy_string(id);
        entry.name = copy_string(name);
        entry.problem = copy_string(problem);
    }
    for * themes if it.id == id { it.* = entry; return; }
    array_add(*themes, entry);
}

parse_line :: (line: string, section: *string, colors: *Theme, name: *string) -> problem: string {
    if !line.count return "";
    if line[0] == #char "[" {
        if line[line.count - 1] != #char "]" return "a section is written [name]";
        section.* = trim(slice(line, 1, line.count - 2));
        return "";
    }
    found, key, value := split_from_left(line, "=");
    if !found return "expected key = \"value\"";
    key = trim(key);
    if section.count key = tprint("%.%", section.*, key);
    value = trim(value);
    if value.count < 2 || (value[0] != #char "\"" && value[0] != #char "'") || value[value.count - 1] != value[0] {
        return tprint("the value of % goes in quotes", key);
    }
    value = slice(value, 1, value.count - 2);
    if key == "name" { name.* = value; return ""; }
    field := theme_color_for_key(colors, key);
    if !field return tprint("unknown key %", key);
    color, ok := parse_hex_color(value);
    if !ok return tprint("% is \"%\", not \"#RRGGBB\" or \"#RRGGBBAA\"", key, value);
    field.* = color;
    return "";
}

// The line up to a # that isn't inside quotes.
strip_comment :: (line: string) -> string {
    quote: u8;
    for i: 0..line.count - 1 {
        c := line[i];
        if quote {
            if c == quote quote = 0;
        } else if c == #char "\"" || c == #char "'" {
            quote = c;
        } else if c == #char "#" {
            return slice(line, 0, i);
        }
    }
    return line;
}

color_is_dark :: (c: Color) -> bool {
    r := cast(float) (c & 0xFF);
    g := cast(float) ((c >> 8) & 0xFF);
    b := cast(float) ((c >> 16) & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
}

embed_theme :: (id: string) -> string {
    path := tprint("%/../../themes/%.toml", #filepath, id);
    text, ok := read_entire_file(path);
    assert(ok, "Missing theme file %", path);
    return text;
}
