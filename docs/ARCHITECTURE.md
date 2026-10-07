# Uppies architecture

## Layout

```
build.jai                    Build metaprogram (debug / release / run); compiles HLSL / Metal shaders
src/main.jai                 Entry point, frame loop, frame clock
src/core/                    Rects and rect cutting, sRGB colors, damping, springs, easing
src/platform/                Window, input, cursor, OS services
    platform.jai             The platform API + shared input state (OS independent)
    platform_windows.jai     Win32 implementation
    platform_macos.jai       Cocoa implementation
src/render/                  Everything that turns a frame into pixels
    draw.jai                 The draw list: one 96-byte instance per primitive
    font.jai                 FreeType glyph cache + shelf-packed atlas
    renderer.jai             Backend interface, stats, settings
    d3d11/                   Direct3D 11 backend + its shader (ui.hlsl)
    metal/                   Metal backend + its shader (ui.metal, a port of ui.hlsl)
src/core/json.jai            JSON parser (tree) and string escaping
src/core/pdf.jai             PDF writer: pages of text, lines, rectangles and paths in the standard fonts
src/core/time.jai            Civil dates, RFC 3339 timestamps, formatting
src/core/format.jai          Money (integer cents) and number formatting
src/net/http_windows.jai     HTTPS over WinHTTP (synchronous; called from worker threads)
src/net/http_macos.jai       HTTPS over NSURLSession (synchronous; called from worker threads)
src/up/                      The Up API: model + parsing, store, encrypted store file, threaded client, sample data
src/ui/                      Immediate-mode widgets (focus, text input, popups, scrolling, tooltips), theme
src/app/                     The console: sync engine, analytics, recurring payments, pages, charts, inspector, printing, test scripts
data/                        Mirrored next to the exe (fonts go in data/fonts/)
assets/icon.png              256 px icon master; build.jai turns it into the exe's icon
```

Layering is strictly downward: `app` uses `ui`, `render`, `platform` and `core`; `render`
never knows about widgets; nothing below `platform` knows about the OS.

## Frame loop

`main` in `main.jai`:

1. Pump OS messages.
2. If nothing wants a frame, **sleep in the OS** (`MsgWaitForMultipleObjectsEx`) until a
   message arrives. A frame is wanted when input arrived (`platform.needs_redraw`), for one
   frame after input (immediate-mode UIs settle a frame later), while any animation is
   moving (`ui.animating`), or in continuous mode. An idle window uses no CPU or GPU.
3. Wait on the swap chain's **frame latency waitable** (maximum latency 1): block until the
   display can take a new frame.
4. Pump again, so input that arrived during the wait makes this frame.
5. `run_frame`: build the UI (which fills the draw list), one upload, one draw, present.

Waiting *before* reading input means a frame shows input at most one refresh old. Every
wait is paired with a present, or the swap chain's latency accounting drifts.

`dt` is measured, clamped to 100 ms, and after sleeping assumed to be one refresh (the
gap since the last frame says nothing about the next). Animations use `damp` (exponential,
frame-rate independent) or `Spring` (sub-stepped, stable at any frame time), so motion is
identical at 60 Hz and 360 Hz.

Win32 runs a modal loop while the window is dragged or resized. During it, a timer and
`WM_SIZE` call `platform.modal_frame`, so content keeps animating and redraws at the new
size live. The loop can start inside step 4's pump, after the main loop has waited, so a wait
not yet followed by a present is never repeated (it would block until the timeout), and the
main loop waits again before `run_frame` if the modal loop presented in between.

## Rendering

The whole UI is **one instanced draw call** with no vertex or index buffer:

- Every primitive is a `Draw_Instance` (96 bytes): rect, corner radii, clip rect, two fill
  colors (vertical gradient), border color and width, kind, and an atlas rect for glyphs.
- The vertex shader expands each instance into a quad from `SV_VertexID`, grown by a pixel
  for antialiasing (or by 3 sigma for shadows), and **clips it on the GPU** by shrinking the
  quad to the clip rect, so clipping never splits the batch and clipped pixels are never shaded.
- The pixel shader evaluates a signed distance function: rounded boxes with per-corner
  radii and borders, an analytic **Gaussian shadow** of a rounded box (closed-form along x,
  4 samples along y), or a glyph's coverage. Gradients are dithered against banding.
- Colors are sRGB and blended in sRGB like browsers and design tools; text coverage gets a
  luminance-dependent correction so light-on-dark text isn't thin.
- Output is premultiplied alpha. Painter's order = submission order.

Per frame the CPU sends the instance array (`Map(WRITE_DISCARD)`, no stall) plus only the
atlas rows new glyphs touched. Shaders are compiled at **build time** (`build.jai` →
`D3DCompile`) and embedded as byte arrays: no runtime shader compiler, no startup compile,
shader errors are build errors.

Presentation: flip-model swap chain (`FLIP_DISCARD`, two buffers, `DXGI_SCALING_NONE`),
frame latency waitable, `ALLOW_TEARING` when vsync is off (uncapped and VRR), no GDI
redirection surface (`WS_EX_NOREDIRECTIONBITMAP`). The first frame is rendered before the
window is shown, so it never flashes white. A lost device (driver update, TDR) is
recreated from CPU-side state.

**Metal (macOS)** draws the same instances with the same shading (`metal/ui.metal` is a port of
`ui.hlsl`; the instance buffer is read by `instance_id`, so there is no vertex descriptor). The
drawable is acquired in `renderer_wait_for_frame`: with vsync, the layer has two drawables, so
`nextDrawable` blocks until the display has released one, the counterpart of the frame latency
waitable. Without vsync, `displaySyncEnabled` is off and a third drawable keeps frames coming
(uncapped). During a live resize, frames present inside the Core Animation transaction that
resizes the layer (`presentsWithTransaction`), so content never lags the window edge. Instance
buffers are a ring of three, one per frame the GPU may still be reading. `build.jai` compiles
`ui.metal` with Xcode's `metal` and `metallib` and embeds the library; this needs the Metal
Toolchain component once (`xcodebuild -downloadComponent MetalToolchain`). The executable is
linked with Apple's `ld`, since Jai's bundled lld can't read the macOS 27 SDK's library stubs.

Why D3D11 and not D3D12: D3D12's advantages are cheap submission of many draws and explicit
multithreading. At one draw per frame neither applies, while presentation, which does
matter, is identical (same DXGI). The backend sits behind a five-procedure interface
(`renderer.jai`), so a D3D12, Metal or Vulkan backend consumes the same draw list.

## Text

`font.jai`: FreeType rasterizes glyphs on demand at the **exact pixel size** they are drawn
at (light hinting, grayscale AA), into one R8 atlas packed in shelves. Glyphs are cached
per (font, pixel size, code point), each with **four horizontal subpixel positions**, so
text uses the font's true advances while every glyph lands on whole pixels. Kerning comes
from the font's `kern` table when it has one. The atlas grows (1024 → 4096) without moving
glyphs; if it ever fills, it is cleared at the start of the next frame, never mid-frame.
A DPI change clears the cache so glyphs re-rasterize at the new sizes.

Fonts: `data/fonts/ui-regular.ttf`, `ui-semibold.ttf`, `ui-light.ttf` if present (Inter is
a good choice), otherwise Segoe UI from the system.

## UI

`ui.jai` is immediate mode: widgets are procedures called each frame with a rectangle that
draw themselves and return what happened (`ui_button` → clicked, `ui_toggle` / `ui_slider` →
changed). Only animation state is retained, in a table keyed by a hash of the widget's
label (text after `##` is id-only), and dropped when a widget isn't drawn for a while.

Layout is **rect cutting** (`cut_top`, `cut_left`, ... in `core/math.jai`): slice pieces off
a rectangle's edges. Sizes are logical units; `px()` scales by the monitor's DPI and `snap()`
rounds edges to whole pixels so 1 px borders stay crisp. `push_clip` / `push_opacity` clip
and fade whole groups (page transitions, scrolling).

## Platforms

`platform.jai` declares the API and owns the OS-independent input state; each OS implements
it in its own file, chosen with `#if OS`. Keys use Windows virtual-key values as the shared
`Key` enum; other platforms translate to them.

**macOS** (`platform_macos.jai`): an `NSWindow` whose content view (an `NSView` subclass defined
from Jai with the Objective-C runtime) is backed by the `CAMetalLayer` the Metal backend draws
into. Sizes are points times `backingScaleFactor` (`platform.dpi_scale`, 2 on Retina). The
main loop sleeps in `nextEventMatchingMask`; `platform_wake` posts an application-defined
event. AppKit's live resize runs inside `sendEvent`, like Win32's modal loop, and
`windowDidResize:` draws through `platform.modal_frame` meanwhile. Command and Control both
drive `Key.CONTROL`, so the Ctrl shortcuts are the Command shortcuts Mac users expect, and the
UI writes them the Mac way (⌘F, ⌘-click) through `shortcut()` and the `PLATFORM_*` strings.

HTTPS is an ephemeral `NSURLSession` (no cookies or cache on disk): each request hands it a
completion block, a Block-ABI literal built from Jai that captures one pointer, and the worker
waits on a dispatch semaphore the block signals. AES-256-GCM is CommonCrypto's one-shot GCM.
`platform_protect`, DPAPI's counterpart, seals a secret with AES-GCM under a 32-byte key kept as
a generic password in the login Keychain (made on first use, never replaced if it can't be
read), with the entropy in the authenticated data; so `token.bin` and `store.uppies` have the
same layout as on Windows. Only the packaged app (a release build run from `Uppies.app`,
`platform_uses_keychain`) uses the Keychain: every other build is a new app to it after each
link, and would be asked for the key every time. Those keep the key in `local.key` (mode 0600)
and all their files in `Uppies Dev` beside `Uppies`, since data sealed with one key is deleted
by a build holding the other. Icons are Unicode symbols from Apple Symbols and Menlo standing in for
the Segoe MDL2 code points (`icon_code_point` in `ui/theme.jai`). The Objective-C calls go through
`objc_msgSend` cast to each signature; floats have wrappers of their own, since the compiler
merged polymorphic wrappers' instantiations whose argument types differed. `jai build.jai - release bundle`
also makes `bin/Uppies.app`: the executable, `data/` in `Contents/Resources` (found through
`resource_dir`), an `.icns` made from `assets/icon.png`, an `Info.plist`, and an ad-hoc signature.

To add Linux:

1. `src/platform/platform_linux.jai`: window, event pump, wait for events, DPI scale, cursor;
   `#load` it in `platform.jai`.
2. `src/render/vulkan/`: the five renderer procedures and a port of `ui.hlsl` (the instance
   layout and shading model stay the same); `#load` in `renderer.jai`.
3. Font candidate paths for the platform's UI font in `ui/theme.jai`.
4. Shader compilation for that backend in `build.jai`.

## Data flow

`up/client.jai` queues requests for two worker threads; each finished request posts
`WM_APP_WAKE`, so the UI loop wakes, takes the replies (`api_take_completed`) and hands them to
`app/sync.jai`, which parses them into `up/store.jai`. Every store change bumps
`store.version`; `app/analytics.jai`, `app/recurring.jai` and each page's cached rows recompute
only when the version (or a filter) changes.

**Recurring payments.** The API has no scheduled payments (only the Open Banking API does, and
card subscriptions are charged by the merchant anyway), so `app/recurring.jai` finds them in the
history. It groups transactions by account, merchant and direction (leaving out transfers,
purchases made in person and money into savers), splits card charges by price, joins price
groups that follow one another on one schedule (a price rise), fits the gaps between charges to
weekly through yearly, and predicts the next date and amount. Bills and pay stay whole, since
their amounts vary. Series the customer hides are kept in `user.bin`, sealed with
`platform_protect` and apart from `store.uppies`, which is thrown away with the token. The
self-test runs it over the sample history, which has the cases (a price rise, two subscriptions
from one merchant, the 31st, a cancellation, a yearly renewal, quarterly bills), and over a
made-up one for the edge cases. Sample-data mode answers the same requests from `up/demo.jai`, so paging,
parsing, errors and writes all run the real code.

**Local data.** `up/store_file.jai` saves the store to `%APPDATA%/Uppies/store.uppies`
(`~/Library/Application Support/Uppies` on macOS, where CommonCrypto and the Keychain key take
the place of CNG and DPAPI), a format
of our own: a small authenticated header (magic, version, DPAPI-wrapped key, nonce), then the
payload as varint-encoded records (accounts, categories, tags, transactions referring to them by
index, plus sync state), encrypted with AES-256-GCM (Windows CNG). The key is new on every save
and wrapped with DPAPI using the access token as entropy. Serializing takes a few milliseconds on
the UI thread; encryption, DPAPI and the flushed, atomic write (temp file + rename) run on a
writer thread. `app/local_data.jai` decides when: after a change has been quiet for 1.5 s, at
least every 15 s during a long download, and at exit.

`sync_start` opens the file before the first frame, so the console appears with the saved data.
Once the ping succeeds, `sync.jai` catches up (categories, tags, balances, then a transaction
window back 45 days, to the oldest held transaction, and past the last sync), resumes an
interrupted history download with `filter[until]`, and every 7 days re-reads the whole history
(`Refresh_Kind.FULL`), since the API has no change feed. Each window replaces what the store had
for it in one step, keeping category and tag edits made while it was in flight. The self-test
checks AES-GCM against a NIST vector, a field-by-field round trip, and that a tampered file or
another token is rejected. Test runs can use `-data-dir PATH` and `-cache-demo`.

Timers (caret blink, tooltip delay, toasts, auto-refresh, relative times) don't keep the loop
running: they call `ui_wake_at`, and the loop sleeps until then. `ui.time` is wall-clock;
animations step by `dt`.

## Printing

Documents are saved as PDFs, written by the app itself (no library, no print driver), in three
layers:

- `core/pdf.jai` writes the file: pages of text, lines, rectangles and Bézier paths, in
  top-left coordinates like the UI. Text uses Helvetica and Courier, which every PDF reader
  has built in, so nothing is embedded and a page is a few kilobytes; UTF-8 is written as
  WinAnsi (Western European text and the usual typography; emoji are left out, anything else
  prints as "?"). Widths come from the fonts' metrics, so text can be measured, wrapped and
  aligned.
- `app/print.jai` is the page design shared by every document (`Print_Doc`): the Uppies
  header, blocks that flow down the page and onto new pages (title, amount, sections of
  label/value fields, notes), a footer on every page saying it was made with Uppies, when,
  and the page number, and saving through the Save dialog (`platform_save_file_dialog`).
- One file per kind of document. `app/print_transaction.jai` is the transaction record behind
  the inspector's print button (Ctrl+P). A new document (a monthly statement, a tag's report)
  is a procedure that calls `print_begin`, the blocks and `print_finish`, then `print_save`.

Everything is built in temporary storage within one frame. The self-test checks that a
transaction's PDF and a multi-page one have valid cross-references, and the `pdf PATH` script
step saves the inspected transaction without the dialog.

## Next steps

- Text shaping (HarfBuzz) for ligatures, GPOS kerning and complex scripts.
- Text input widget (the platform already delivers UTF-32 code points in `input.text`).
- GPU timing via timestamp queries in the stats.
- A flexible row/column layout helper on top of rect cutting.
- Image support: a second atlas or bindless textures, a fourth instance kind.
