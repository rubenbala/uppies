# Themes

Each theme is a [TOML](https://toml.io) file: a name, then colors in sections. The files here are
built into Uppies (embedded at build time); pick one in **Settings → Display → Theme**.

| File                    | Theme            |       |
|-------------------------|------------------|-------|
| `uppies-dark.toml`      | Uppies Dark      | Dark (the default) |
| `uppies-light.toml`     | Uppies Light     | Light |
| `nord.toml`             | Nord             | Dark  |
| `dracula.toml`          | Dracula          | Dark  |
| `solarized-light.toml`  | Solarized Light  | Light |
| `catppuccin-latte.toml` | Catppuccin Latte | Light |

## Your own

Put `.toml` files in the themes folder beside Uppies' settings (`%APPDATA%\Uppies\themes`, or
`~/Library/Application Support/Uppies/themes`). **Open themes folder** in Settings makes it, the
first time with `my-theme.toml`, a copy of the current theme to start from. Edit a file, then
**Reload themes**. A file named like a built-in one (`nord.toml`) replaces it.

## Format

```toml
name = "My theme"

[accent]
base = "#3DDC97"        # A comment runs to the end of the line.
soft = "#3DDC9722"      # #RRGGBBAA: with an alpha.
```

Colors are `"#RRGGBB"` or `"#RRGGBBAA"`. A key can also be written whole, outside any section:
`accent.base = "#3DDC97"`. **Colors a theme leaves out are Uppies Dark's**, so a theme can change
only what it needs to. Whether a theme is light or dark (for the window's title bar) follows
`surface.background`. If a file has a mistake, choosing the theme says which line.

| Key | Colors |
|-----|--------|
| `surface.background` | Behind the panels |
| `surface.chrome` | Top bar and status bar |
| `surface.panel`, `surface.panel_header` | Panels and their headers |
| `surface.raised` | Inputs and buttons |
| `surface.hover`, `surface.active` | Under the mouse; pressed or selected |
| `surface.border`, `surface.border_strong` | Outlines; outlines under the mouse, dialogs |
| `surface.divider` | Lines between rows and sections |
| `surface.grid` | Chart gridlines |
| `surface.shadow` | Under menus, tooltips and dialogs (give it an alpha) |
| `surface.scrim` | Over the window behind a dialog (give it an alpha) |
| `text.primary`, `text.secondary`, `text.muted`, `text.faint` | Text, from most to least prominent |
| `accent.base`, `accent.hover`, `accent.pressed` | Focus, selection, links and the primary button |
| `accent.soft`, `accent.wash` | Selected rows and lighter tints (give them an alpha) |
| `accent.text` | Text on an accent fill |
| `status.positive` | Money in |
| `status.held` | Money on hold, warnings |
| `status.danger`, `status.danger_hover` | Errors and destructive buttons |
| `status.info` | Informational chips |
| `chart.out`, `chart.in`, `chart.line` | Money out and in, and line charts |
| `category.good_life`, `category.personal`, `category.home`, `category.transport` | Up's parent categories |
| `category.other` | Uncategorised |

Uppies' self-test (`uppies.exe -selftest`) checks that every built-in theme sets every key and
that its text is readable on its panels.
