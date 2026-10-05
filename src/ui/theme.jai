// Colors, type sizes and metrics. Sizes are logical units; multiply by
// ui.scale (see px) for pixels.

Theme :: struct {
    background     := #run rgb(0x0E1014);
    sidebar        := #run rgb(0x12151A);
    surface        := #run rgb(0x181B21);
    surface_raised := #run rgb(0x1E222A);
    surface_hover  := #run rgb(0x252A33);
    border         := #run rgba(0xFFFFFF, 16);
    border_strong  := #run rgba(0xFFFFFF, 28);
    divider        := #run rgba(0xFFFFFF, 10);

    text           := #run rgb(0xECEEF2);
    text_secondary := #run rgb(0xA0A7B4);
    text_muted     := #run rgb(0x6B7280);

    accent         := #run rgb(0x7187FF);
    accent_top     := #run rgb(0x7E93FF);
    accent_bottom  := #run rgb(0x5C72F2);
    accent_soft    := #run rgba(0x7187FF, 40);
    on_accent      := #run rgb(0xFFFFFF);

    success        := #run rgb(0x3DD68C);
    warning        := #run rgb(0xF5B14C);
    danger         := #run rgb(0xF06A6A);

    shadow         := #run rgba(0x000000, 110);

    radius_card    := 12.0;
    radius_control := 8.0;
    control_height := 34.0;

    font_size_small   := 12.0;
    font_size_body    := 14.0;
    font_size_heading := 16.0;
    font_size_title   := 24.0;
    font_size_display := 34.0;
}

theme: Theme;

Fonts :: struct {
    regular:  *Font;
    semibold: *Font;
    light:    *Font;   // Large numbers and display text.
}

fonts: Fonts;

// Drop Inter (or any .ttf) into data/fonts/ with these names to use it;
// otherwise the platform's UI font is used.
#if OS == .WINDOWS {
    FONT_REGULAR_CANDIDATES  :: string.["data/fonts/ui-regular.ttf",  "C:/Windows/Fonts/segoeui.ttf"];
    FONT_SEMIBOLD_CANDIDATES :: string.["data/fonts/ui-semibold.ttf", "C:/Windows/Fonts/seguisb.ttf", "C:/Windows/Fonts/segoeuib.ttf"];
    FONT_LIGHT_CANDIDATES    :: string.["data/fonts/ui-light.ttf",    "C:/Windows/Fonts/segoeuisl.ttf", "C:/Windows/Fonts/segoeuil.ttf"];
}

theme_load_fonts :: () -> bool {
    fonts.regular  = load_font(FONT_REGULAR_CANDIDATES);
    fonts.semibold = load_font(FONT_SEMIBOLD_CANDIDATES);
    fonts.light    = load_font(FONT_LIGHT_CANDIDATES);
    if !fonts.regular return false;
    if !fonts.semibold fonts.semibold = fonts.regular;
    if !fonts.light    fonts.light    = fonts.regular;
    return true;
}
