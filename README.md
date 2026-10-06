# Uppies

A desktop console for an [Up](https://up.com.au) bank account, built on the
[Up API](https://developer.up.com.au). Written in [Jai](https://jai.community) on Direct3D 11:
one draw call per frame, about 0.5–0.8 ms of CPU per frame in release, and no CPU at all while
nothing changes.

Pages sit in a tab bar along the top (there is no sidebar):

| Page         | Answers                                                                 |
|--------------|-------------------------------------------------------------------------|
| Overview     | Where do I stand? Net position, balances with 30-day trends, cash flow, this month's spending, recent activity, and what needs attention (holds, uncategorised purchases, sync problems). |
| Transactions | Find and fix transactions: search, filters, sortable table grouped by day, and an inspector to change the category and tags, or save the transaction as a PDF. Ctrl+click (or Shift+click) several to tag them all at once. |
| Accounts     | How each balance is moving: balance history (reconstructed from transactions), monthly ledger, money in and out by month. Ctrl+click (or Shift+click) several to see them added together. |
| Spending     | Where the money goes: categories grouped by parent with comparisons, 12-month stacked chart, top merchants. |
| Tags         | What each tag cost, by category and by month.                           |
| Webhooks     | Create, ping and delete webhooks; delivery health and logs with payloads. |
| Settings     | Connection, data (history depth, auto-refresh, transfer handling), display, diagnostics, keys. |

## Connecting

Create a personal access token at <https://api.up.com.au/getting_started> and paste it into the
connect screen. With "Remember on this PC" the token is stored encrypted with Windows DPAPI in
`%APPDATA%\Uppies\token.bin` (only your Windows account can decrypt it). It is only ever sent to
`api.up.com.au`. **Explore with sample data** runs the whole app against an offline simulation
of the API instead.

Uppies can change categories and tags and manage webhooks; it cannot move money (the API
doesn't allow it).

## Your data on this PC

Uppies keeps what it has downloaded in `%APPDATA%\Uppies\store.uppies`, so it opens instantly
and afterwards only asks Up for what changed. The file is encrypted with AES-256-GCM under a
fresh random key on every save; that key is protected by Windows DPAPI together with your access
token, so only your Windows account, with that same token, can read it. A file that was altered,
damaged or written by another token is never used: Uppies deletes it and downloads again.

Each time it opens, Uppies shows the saved data, then re-reads balances, categories and the last
45 days of transactions (further back if something is still pending or it has been a while).
Up has no way to ask "what changed?", so once a week it also re-reads the whole history in the
background, to catch changes to older transactions (a category set in the Up app, say).

**Settings > Data** shows the file's size and the last full check, and has **Delete local
data**, which removes the file and downloads everything again, and a switch to stop keeping a
copy at all.

## Build and run

Requires the Jai compiler on the PATH (`jai`) and Windows 10 or newer.

```bash
jai build.jai                 # debug build -> bin/uppies.exe
jai build.jai - release       # optimized, no console window
jai build.jai - run           # build, then launch
```

Command-line options, mostly for testing:

| Option                 | Effect                                                            |
|------------------------|-------------------------------------------------------------------|
| `-demo`                | Start with sample data                                            |
| `-selftest`            | Run the parser/store/format/DPAPI checks and exit (0 = pass)      |
| `-size 1440x900`       | Initial window size (logical units)                               |
| `-page spending`       | Open on a page                                                    |
| `-script "steps"`      | Drive the app off screen and save PNGs and PDFs (see `src/app/script.jai`) |
| `-hidden -quit-after N`| Run off screen for N seconds and report frames drawn and CPU time |
| `-continuous`          | Render every frame (benchmarking)                                 |

Scripted and timed runs never read or write the saved token or settings.

## Keys

| Key                     | Action                                        |
|-------------------------|-----------------------------------------------|
| Ctrl+1..7, Ctrl+Tab     | Switch page                                   |
| / or Ctrl+F             | Search transactions                           |
| F5 or Ctrl+R            | Refresh from Up                               |
| ↑ ↓ PgUp PgDn Home End  | Move through the focused table                |
| Ctrl+click, Shift+click | Choose several transactions, to tag them together, or several accounts, to add them together |
| Ctrl+P                  | Save the transaction in the inspector as a PDF |
| Esc                     | Close a menu, clear a search, close the inspector |
| Tab / Shift+Tab         | Move keyboard focus; Enter or Space activates |

## Fonts

Segoe UI for text, Cascadia Mono (or Consolas) for identifiers and timestamps, Bahnschrift for
headline figures, Segoe MDL2 Assets for icons, and Segoe UI Symbol/Emoji as fallbacks. To use
other fonts, put `ui-regular.ttf`, `ui-semibold.ttf`, `ui-light.ttf`, `ui-mono.ttf` or
`ui-numeric.ttf` in `data/fonts/`.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is put together.
