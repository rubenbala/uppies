# Third-party software

Uppies itself is released under the [MIT License](LICENSE). Release builds ship with one
third-party component, listed below.

## FreeType

`freetype.dll`, which sits next to `uppies.exe`, is the [FreeType](https://freetype.org) font
rasterizer. Uppies uses it under the FreeType License (FTL); FreeType is dual-licensed under the
FTL or the GNU GPL v2, and the FTL option applies here.

> Portions of this software are copyright © The FreeType Project (https://freetype.org).
> All rights reserved.

The DLL is the copy distributed with the Jai compiler's `modules/freetype` module and is copied
into `bin/` by `build.jai`; it is not modified. It statically includes
[zlib](https://zlib.net) (Copyright © 1995–2022 Jean-loup Gailly and Mark Adler), which is
under the zlib License.

When distributing a release, include this file next to the executable, and the FreeType License
text (`FTL.TXT`, from <https://gitlab.freedesktop.org/freetype/freetype/-/blob/master/docs/FTL.TXT>)
if you ship `freetype.dll`.

## Fonts

Uppies does not bundle any fonts. It uses the ones already installed with Windows (Segoe UI,
Cascadia Mono, Bahnschrift, Segoe MDL2 Assets, Segoe UI Symbol and Emoji) and loads them at run
time from `C:\Windows\Fonts`. Fonts you place in `data/fonts/` are your own to license.

## Theme palettes

Four of the built-in themes (`themes/`) take their colors from published palettes, all under the
MIT License: [Nord](https://www.nordtheme.com) (Arctic Ice Studio and Sven Greb),
[Dracula](https://draculatheme.com) (Zeno Rocha), [Solarized](https://ethanschoonover.com/solarized/)
(Ethan Schoonover) and [Catppuccin](https://catppuccin.com) (the Catppuccin organization). Only
the color values are used; no code from these projects is included.

## Windows APIs

Uppies calls Windows system libraries (user32, kernel32, crypt32, bcrypt, winhttp, Direct3D 11
and so on). These are part of Windows and are not redistributed.

## macOS

On macOS, FreeType is linked into the executable statically (same license and notice as above).
Uppies uses the fonts that come with macOS (SF Pro, SF Mono, Apple Symbols, Menlo) from
`/System/Library/Fonts`, and the system frameworks (AppKit, Foundation, CoreFoundation, Metal,
Security, and CommonCrypto in libSystem). None of these are redistributed.
