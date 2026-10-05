# Uppies

A high-performance desktop app written in [Jai](https://jai.community) on Direct3D 11.
Built from first principles for fast, smooth animation:

- **One draw call per frame.** Every panel, border, gradient, shadow and glyph is a 96-byte
  instance shaded by a distance function; clipping happens on the GPU, so nothing splits the batch.
- **One frame of latency.** A flip-model swap chain with a frame latency waitable: the app waits
  for the display *before* reading input.
- **Zero cost when idle.** The loop renders only while input arrives or something animates,
  and otherwise sleeps in the OS.
- **Crisp text at any DPI.** FreeType glyphs rasterized at their exact pixel size, cached with
  quarter-pixel positioning; per-monitor DPI aware.
- **Frame-rate independent animation.** Springs and exponential damping driven by time; vsync
  off renders uncapped (with tearing allowed for VRR displays).

Measured on a GTX 1080 Ti at 1786×1116 (release): ~0.16 ms CPU per frame, ~1,900 fps
uncapped, 0 ms CPU while idle.

## Build and run

Requires the Jai compiler on the PATH (`jai`) and Windows 10 or newer.

```bash
jai build.jai                 # debug build -> bin/uppies.exe
jai build.jai - release       # optimized, no console window
jai build.jai - run           # build, then launch
```

Shaders are compiled at build time; a shader error fails the build.

## Keys

| Key        | Action                                  |
|------------|-----------------------------------------|
| V          | Toggle vsync (off = uncapped)           |
| C          | Toggle continuous rendering (benchmark) |
| Ctrl+1..4  | Switch page                             |

## Fonts

By default the app uses Segoe UI. To use another font (Inter works well), put
`ui-regular.ttf`, `ui-semibold.ttf` and `ui-light.ttf` in `data/fonts/`.

## Platforms

Windows only for now. The platform layer (`src/platform/`) and the renderer backend
(`src/render/d3d11/`) are the only OS-specific code; macOS and Linux slot in beside them.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
