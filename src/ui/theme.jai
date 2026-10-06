// Colors, type sizes and metrics. Sizes are logical units; multiply by
// ui.scale (see px) for pixels.
//
// The palette is deliberately quiet: neutral surfaces a step apart, crisp
// solid borders, and color only where it means something. Up's coral marks
// focus, selection and the primary action; green is money coming in, amber
// is money on hold, red is failure. Chart hues are validated for color
// vision deficiency against the panel surface.

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
    info           := #run rgb(0x72A9F5);

    chart_out      := #run rgb(0x3987E5);
    chart_in       := #run rgb(0x26A37A);
    chart_line     := #run rgb(0x6FA8EE);

    shadow         := #run rgba(0x000000, 150);

    brand_top      := #run rgb(0xFF9C6E);   // The app icon's plate and glyph (assets/icon.png).
    brand_bottom   := #run rgb(0xEE5068);
    brand_glyph    := #run rgb(0xFFFFFF);

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

// Up's parent categories, in a fixed order with fixed hues: color follows
// the category, never its rank. Validated (dark surface #14171B): every
// adjacent pair separates under deuteranopia (ΔE ≥ 13) and normal vision.
PARENT_CATEGORY_IDS    :: string.["good-life", "personal", "home", "transport"];
PARENT_CATEGORY_COLORS :: Color.[#run rgb(0xE0B021), #run rgb(0xE8702A), #run rgb(0xB57BEB), #run rgb(0x3987E5)];
UNCATEGORISED_COLOR    :: #run rgb(0x59606A);

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
}

theme_load_fonts :: () -> bool {
    fonts.regular  = load_font(FONT_REGULAR_CANDIDATES);
    fonts.semibold = load_font(FONT_SEMIBOLD_CANDIDATES);
    fonts.light    = load_font(FONT_LIGHT_CANDIDATES);
    fonts.mono     = load_font(FONT_MONO_CANDIDATES);
    fonts.icons    = load_font(FONT_ICON_CANDIDATES);
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
}
