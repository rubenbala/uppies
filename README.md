# Uppies

**An unofficial desktop client for [Up](https://up.com.au).**

A desktop console for an Up bank account, built on the
[Up API](https://developer.up.com.au). Written in [Jai](https://jai.community) on Direct3D 11:
one draw call per frame, about 0.5–0.8 ms of CPU per frame in release, and no CPU at all while
nothing changes.

> **Disclaimer.** Uppies is an independent, unofficial app. It is not affiliated with, endorsed
> by or sponsored by Up or Bendigo and Adelaide Bank Limited. "Up" is a trademark of its owner
> and is used here only to say which bank Uppies works with. Uppies is provided as is, without
> warranty of any kind, and nothing in it is financial advice.

Pages sit in a tab bar along the top (there is no sidebar):

| Page         | Answers                                                                 |
|--------------|-------------------------------------------------------------------------|
| Overview     | Where do I stand? Net position, balances with 30-day trends, cash flow, this month's spending, recent activity, and what needs attention (holds, uncategorised purchases, sync problems). |
| Transactions | Find and fix transactions: search, filters, sortable table grouped by day, and an inspector to change the category and tags, or save the transaction as a PDF. Ctrl+click (or Shift+click) several to change their category or tag them all at once. |
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

## Security

Uppies never sends your token anywhere but `api.up.com.au`, and the Up API can't be used to
move money. Anyone who has your token or can run code as your Windows user can still read your
data, so revoke the token at <https://api.up.com.au/getting_started> if you suspect it has
leaked. Please report vulnerabilities privately (see [SECURITY.md](SECURITY.md)), and never post
a real token, `token.bin`, `store.uppies` or screenshots of real data in an issue; use `-demo`
mode instead.

## Build and run

Requires the Jai compiler on the PATH (`jai`) and Windows 10 or newer. Jai is currently in a
closed beta, so you need beta access to build from source.

```bash
jai build.jai                 # debug build -> bin/uppies.exe
jai build.jai - release       # optimized, no console window
jai build.jai - run           # build, then launch
```

**macOS.** The same commands build `bin/uppies` with a Metal renderer, on Apple silicon with
macOS 13 or newer. It needs Xcode and, once, its Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`). Everything works as on Windows: the token and
the encrypted local copy are protected by a key in your login Keychain, and the data is kept in
`~/Library/Application Support/Uppies`. An ad-hoc signed build is a new app to the Keychain each
time it is rebuilt, so macOS asks once whether it may use the Uppies key; set
`UPPIES_SIGN_IDENTITY` to a codesigning identity to sign with it instead and keep the Keychain's
trust across builds.

```bash
jai build.jai - release bundle   # macOS: also make bin/Uppies.app (icon, Info.plist, ad-hoc signed)
```

The bundle runs on the Mac that built it. Giving it to others needs a Developer ID signature and
notarization.

Command-line options, mostly for testing:

| Option                 | Effect                                                            |
|------------------------|-------------------------------------------------------------------|
| `-demo`                | Start with sample data                                            |
| `-selftest`            | Run the parser/store/format/crypto checks and exit (0 = pass)     |
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
| Ctrl+click, Shift+click | Choose several transactions, to recategorise or tag them together, or several accounts, to add them together |
| Ctrl+P                  | Save the transaction in the inspector as a PDF |
| Esc                     | Close a menu, clear a search, close the inspector |
| Tab / Shift+Tab         | Move keyboard focus; Enter or Space activates |

## Fonts

Segoe UI for text, Cascadia Mono (or Consolas) for identifiers and timestamps, Bahnschrift for
headline figures, Segoe MDL2 Assets for icons, and Segoe UI Symbol/Emoji as fallbacks. To use
other fonts, put `ui-regular.ttf`, `ui-semibold.ttf`, `ui-light.ttf`, `ui-mono.ttf` or
`ui-numeric.ttf` in `data/fonts/`.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is put together.

## License

[MIT](LICENSE) © 2026 Ruben Bala. Third-party components are listed in
[THIRD_PARTY.md](THIRD_PARTY.md).
