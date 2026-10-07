// Colors, type sizes and metrics. Sizes are logical units; multiply by
// ui.scale (see px) for pixels.
//
// The palette is deliberately quiet: neutral surfaces a step apart, crisp
// solid borders, and color only where it means something. Up's coral marks
// focus, selection and the primary action; green is money coming in, amber
// is money on hold, red is failure. Chart hues are validated for color
// vision deficiency against the panel surface.
//
// These defaults are the Uppies Dark theme. Themes are text files that
// override the colors (see ui/themes.jai and themes/ at the repo root).

Theme :: struct {
    background     := #run rgb(0x0B0D10);   // Behind the panels.
    chrome         := #run rgb(0x101317);   // Top bar, status bar.
    panel          := #run rgb(0x14171B);
    panel_header   := #run rgb(0x171A1F);
    raised         := #run rgb(0x1B1F25);   // Inputs, buttons.
    hover          := #run rgb(0x21262D);
    active         := #run rgb(0x29303A);
    border         := #run rgb(0x262B32);
    border_strong  := #run rgb(0x363D47);
    divider        := #run rgb(0x1D2127);
    grid           := #run rgb(0x22272E);

    text           := #run rgb(0xE6E9ED);
    text_secondary := #run rgb(0xA3AAB4);
    text_muted     := #run rgb(0x737B86);
    text_faint     := #run rgb(0x4E5560);

    accent         := #run rgb(0xFF7A64);   // Up's coral.
    accent_hover   := #run rgb(0xFF917E);
    accent_pressed := #run rgb(0xE8634E);
    accent_soft    := #run rgba(0xFF7A64, 34);
    accent_wash    := #run rgba(0xFF7A64, 18);
    on_accent      := #run rgb(0x1E0F0B);

    positive       := #run rgb(0x52C48E);   // Money in.
    held           := #run rgb(0xE6B04A);   // On hold / pending.
    danger         := #run rgb(0xF0646C);
    danger_hover   := #run rgb(0xFFB3B7);
    info           := #run rgb(0x72A9F5);

    chart_out      := #run rgb(0x3987E5);
    chart_in       := #run rgb(0x26A37A);
    chart_line     := #run rgb(0x6FA8EE);

    // Up's parent categories, with fixed hues: color follows the category,
    // never its rank. Validated (dark surface #14171B): every adjacent pair
    // separates under deuteranopia (ΔE ≥ 13) and normal vision.
    category_good_life := #run rgb(0xE0B021);
    category_personal  := #run rgb(0xE8702A);
    category_home      := #run rgb(0xB57BEB);
    category_transport := #run rgb(0x3987E5);
    uncategorised      := #run rgb(0x59606A);

    shadow         := #run rgba(0x000000, 150);
    scrim          := #run rgba(0x000000, 120);   // Over the window behind a dialog.

    radius_panel   := 4.0;
    radius_control := 3.0;
    control_height := 28.0;
    row_height     := 28.0;
    panel_header_height := 34.0;

    font_size_small   := 11.0;
    font_size_body    := 13.0;
    font_size_label   := 12.0;
    font_size_heading := 14.0;
    font_size_metric  := 21.0;
    font_size_display := 34.0;
}

theme: Theme;

// The app icon's plate and glyph (assets/icon.png): the same in every theme.
BRAND_TOP    :: #run rgb(0xFF9C6E);
BRAND_BOTTOM :: #run rgb(0xEE5068);
BRAND_GLYPH  :: #run rgb(0xFFFFFF);

// Up's parent categories, in a fixed order; parent_category_color gives each
// its hue in the current theme.
PARENT_CATEGORY_IDS :: string.["good-life", "personal", "home", "transport"];

parent_category_color :: (slot: int) -> Color {
    if slot == {
        case 0; return theme.category_good_life;
        case 1; return theme.category_personal;
        case 2; return theme.category_home;
        case 3; return theme.category_transport;
    }
    return theme.uncategorised;
}

Fonts :: struct {
    regular:  *Font;
    semibold: *Font;
    light:    *Font;
    mono:     *Font;   // Identifiers, timestamps, raw payloads.
    icons:    *Font;   // Segoe MDL2 Assets.
    numeric:  *Font;   // Instrument-style figures for headline metrics.
}

fonts: Fonts;

// Drop Inter (or any .ttf) into data/fonts/ with these names to use it;
// otherwise the platform's UI font is used.
#if OS == .WINDOWS {
    FONT_REGULAR_CANDIDATES  :: string.["data/fonts/ui-regular.ttf",  "C:/Windows/Fonts/segoeui.ttf"];
    FONT_SEMIBOLD_CANDIDATES :: string.["data/fonts/ui-semibold.ttf", "C:/Windows/Fonts/seguisb.ttf", "C:/Windows/Fonts/segoeuib.ttf"];
    FONT_LIGHT_CANDIDATES    :: string.["data/fonts/ui-light.ttf",    "C:/Windows/Fonts/segoeuisl.ttf", "C:/Windows/Fonts/segoeuil.ttf"];
    FONT_MONO_CANDIDATES     :: string.["data/fonts/ui-mono.ttf",     "C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf"];
    FONT_ICON_CANDIDATES     :: string.["C:/Windows/Fonts/segmdl2.ttf", "C:/Windows/Fonts/SegoeIcons.ttf"];
    FONT_NUMERIC_CANDIDATES  :: string.["data/fonts/ui-numeric.ttf",  "C:/Windows/Fonts/bahnschrift.ttf", "C:/Windows/Fonts/seguisb.ttf"];
    FONT_FALLBACK_CANDIDATES :: string.["C:/Windows/Fonts/seguisym.ttf", "C:/Windows/Fonts/seguiemj.ttf"];
} else #if OS == .MACOS {
    // SF Pro is a variable font; FreeType gives its default instance, so
    // every weight is Regular until named instances are selected. Fonts in
    // data/fonts/ give real weights.
    FONT_REGULAR_CANDIDATES  :: string.["data/fonts/ui-regular.ttf",  "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"];
    FONT_SEMIBOLD_CANDIDATES :: string.["data/fonts/ui-semibold.ttf", "/System/Library/Fonts/SFNS.ttf"];
    FONT_LIGHT_CANDIDATES    :: string.["data/fonts/ui-light.ttf",    "/System/Library/Fonts/SFNS.ttf"];
    FONT_MONO_CANDIDATES     :: string.["data/fonts/ui-mono.ttf",     "/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc"];
    // No macOS font has the Segoe MDL2 icons: they are drawn as Unicode
    // symbols instead (MAC_ICON_SYMBOLS), mostly from Apple Symbols, the
    // rest from the fallbacks. An icon font in data/fonts/ui-icons.ttf is
    // taken to use the MDL2 code points, as on Windows.
    FONT_ICON_CANDIDATES     :: string.["/System/Library/Fonts/Apple Symbols.ttf", "/System/Library/Fonts/SFNS.ttf"];
    FONT_ICON_MDL2           :: "data/fonts/ui-icons.ttf";
    FONT_NUMERIC_CANDIDATES  :: string.["data/fonts/ui-numeric.ttf",  "/System/Library/Fonts/SFNS.ttf"];
    FONT_FALLBACK_CANDIDATES :: string.["/System/Library/Fonts/Apple Symbols.ttf", "/System/Library/Fonts/Menlo.ttc"];
}

theme_load_fonts :: () -> bool {
    fonts.regular  = load_font(FONT_REGULAR_CANDIDATES);
    fonts.semibold = load_font(FONT_SEMIBOLD_CANDIDATES);
    fonts.light    = load_font(FONT_LIGHT_CANDIDATES);
    fonts.mono     = load_font(FONT_MONO_CANDIDATES);
    #if OS == .MACOS {
        icons_are_mdl2 = file_exists(tprint("%/%", resource_dir, FONT_ICON_MDL2));
        fonts.icons = ifx icons_are_mdl2 then load_font(.[FONT_ICON_MDL2]) else load_font(FONT_ICON_CANDIDATES);
    } else {
        fonts.icons = load_font(FONT_ICON_CANDIDATES);
    }
    fonts.numeric  = load_font(FONT_NUMERIC_CANDIDATES);
    if !fonts.regular return false;
    if !fonts.semibold fonts.semibold = fonts.regular;
    if !fonts.light    fonts.light    = fonts.regular;
    if !fonts.mono     fonts.mono     = fonts.regular;
    if !fonts.numeric  fonts.numeric  = fonts.semibold;
    // Each fallback is tried in order for code points the UI font lacks.
    for FONT_FALLBACK_CANDIDATES {
        path := it;
        if file_exists(path) fonts_add_fallback(load_font_file(path));
    }
    return true;
}

// The code point that draws an icon in fonts.icons.
icon_code_point :: (icon: Icon) -> u32 {
    #if OS == .MACOS {
        if !icons_are_mdl2 {
            for MAC_ICON_SYMBOLS if it.icon == icon return it.code_point;
            return 0;
        }
    }
    return cast(u32) icon;
}

// How much larger icons are drawn than asked: the Unicode symbols standing
// in for MDL2 on macOS are drawn smaller within their em square.
icon_scale :: () -> float {
    #if OS == .MACOS {
        if !icons_are_mdl2 return MAC_ICON_SCALE;
    }
    return 1;
}

// Segoe MDL2 Assets code points.
Icon :: enum u32 {
    NONE           :: 0;
    REFRESH        :: 0xE72C;
    SETTINGS       :: 0xE713;
    SEARCH         :: 0xE721;
    CLOSE          :: 0xE711;
    CHEVRON_DOWN   :: 0xE70D;
    CHEVRON_UP     :: 0xE70E;
    CHEVRON_LEFT   :: 0xE76B;
    CHEVRON_RIGHT  :: 0xE76C;
    ARROW_DOWN     :: 0xE74B;
    ARROW_UP       :: 0xE74A;
    COPY           :: 0xE8C8;
    DELETE         :: 0xE74D;
    ADD            :: 0xE710;
    TAG            :: 0xE8EC;
    WARNING        :: 0xE7BA;
    CHECK          :: 0xE73E;
    INFO           :: 0xE946;
    OPEN_EXTERNAL  :: 0xE8A7;
    LINK           :: 0xE71B;
    FILTER         :: 0xE71C;
    LOCK           :: 0xE72E;
    ATTACH         :: 0xE723;
    SYNC           :: 0xE895;
    CALENDAR       :: 0xE787;
    BANK           :: 0xE825;
    LIGHTNING      :: 0xE945;
    VIEW           :: 0xE890;
    HIDE           :: 0xED1A;
    MORE           :: 0xE712;
    EDIT           :: 0xE70F;
    ERROR          :: 0xE783;
    PLUG           :: 0xE703;
    KEYBOARD       :: 0xE765;
    CLOCK          :: 0xE823;
    GLOBE          :: 0xE774;
    NOTE           :: 0xE70B;
    PRINT          :: 0xE749;
    DOWNLOAD       :: 0xE896;
}

#if OS == .MACOS {
    icons_are_mdl2: bool;   // fonts.icons came from data/fonts/ui-icons.ttf.
    MAC_ICON_SCALE :: 1.4;

    // Each icon's stand-in among the symbols macOS's fonts have (outlines
    // only: Apple Color Emoji is bitmaps, which the glyph cache can't draw).
    MAC_ICON_SYMBOLS :: struct { icon: Icon; code_point: u32; }.[
        .{.REFRESH,       0x21BB},   // ↻
        .{.SETTINGS,      0x2699},   // ⚙
        .{.SEARCH,        0x2315},   // ⌕
        .{.CLOSE,         0x2715},   // ✕
        .{.CHEVRON_DOWN,  0x2304},   // ⌄
        .{.CHEVRON_UP,    0x2303},   // ⌃
        .{.CHEVRON_LEFT,  0x2039},   // ‹
        .{.CHEVRON_RIGHT, 0x203A},   // ›
        .{.ARROW_DOWN,    0x2193},   // ↓
        .{.ARROW_UP,      0x2191},   // ↑
        .{.COPY,          0x29C9},   // ⧉
        .{.DELETE,        0x232B},   // ⌫
        .{.ADD,           0xFF0B},   // ＋
        .{.TAG,           0x2317},   // ⌗
        .{.WARNING,       0x26A0},   // ⚠
        .{.CHECK,         0x2713},   // ✓
        .{.INFO,          0x2139},   // ℹ
        .{.OPEN_EXTERNAL, 0x2197},   // ↗
        .{.LINK,          0x26AD},   // ⚭
        .{.FILTER,        0x25BD},   // ▽
        .{.LOCK,          0x25A3},   // ▣
        .{.ATTACH,        0x2398},   // ⎘
        .{.SYNC,          0x27F3},   // ⟳
        .{.CALENDAR,      0x25A6},   // ▦
        .{.BANK,          0x2302},   // ⌂
        .{.LIGHTNING,     0x26A1},   // ⚡
        .{.VIEW,          0x25C9},   // ◉
        .{.HIDE,          0x25CC},   // ◌
        .{.MORE,          0x22EF},   // ⋯
        .{.EDIT,          0x270E},   // ✎
        .{.ERROR,         0x2297},   // ⊗
        .{.PLUG,          0x2301},   // ⌁
        .{.KEYBOARD,      0x2328},   // ⌨
        .{.CLOCK,         0x25F7},   // ◷
        .{.GLOBE,         0x25CE},   // ◎
        .{.NOTE,          0x2261},   // ≡
        .{.PRINT,         0x2399},   // ⎙
        .{.DOWNLOAD,      0x2913},   // ⤓
    ];
}
