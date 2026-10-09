# Uppies

**A fast, native desktop application for your Up account**

<img width="1896" height="1197" alt="Screenshot 2026-10-09 15_36_35 - uppies_4" src="https://github.com/user-attachments/assets/da92e30f-5d8e-425a-9d37-d34d85888b3e" />


Uppies is a desktop app for people who bank with [Up](https://up.com.au). It's meant to feel like
a utility rather than a sleek, minimal banking app. That means lots of information on screen at
once, tables you can search and sort, and keyboard shortcuts for the things you do most.

Uppies runs on Windows and Mac, and a Linux version is coming soon.

It's quick, too. Uppies is written from scratch rather than wrapped around a web page, opens
straight onto your saved data, and uses no CPU at all while you're just looking at it.

> Uppies is an independent, unofficial app. It isn't affiliated with, endorsed by or sponsored by
> Up or Bendigo and Adelaide Bank Limited. "Up" is a trademark of its owner and is only used here
> to say which bank Uppies works with. Uppies is provided as is, without warranty of any kind, and
> nothing in it is financial advice.

> 99% of the code in this application was written by Opus 5.5.

## What it does

**See where you stand.** The Overview page shows your net position, every balance with its trend
over the last 30 days, money in and out, this month's spending and your latest activity. It also
points out anything that needs a look, like held payments or purchases without a category.

**Find any transaction.** Search, filter by account, category, tag or date (financial years
included), and sort however you like. Click a transaction to change its category or tags, or save it as a PDF.
Ctrl+click a few and you can recategorise or tag them all in one go. Made a mistake? Ctrl+Z.

**Understand your spending.** See spending by category and how it compares with previous months,
a 12-month chart, and the merchants you spend the most with. Tag a trip or a project and the Tags
page shows what it cost.

**Keep track of what's recurring.** Uppies picks out your subscriptions, bills and regular income
from your history. You'll see what they add up to each month, what's due in the next 30 days and
when a price goes up. If it gets one wrong, hide it.

**Watch your accounts over time.** Follow each balance month by month, or select a few accounts
to see them added together. Have a home loan that swamps your cash? Click **Configure** beside it
and turn off **Include in totals**. Its balance and activity then stay out of your net position,
cash flow and spending everywhere, and repayments into it count as money out.

If you use Up's webhooks, there's a page to create, test and delete them and to read their
delivery logs.

## Getting started

Uppies runs on Windows 10 and 11, and on Apple silicon Macs with macOS 13 or newer. Linux is
coming soon.

1. Download Uppies from the [latest release](https://github.com/rubenbala/uppies/releases/latest):
   the installer for Windows, or the disk image (`.dmg`) for Mac. On a Mac, open the disk image
   and drag Uppies into Applications.
2. Make a personal access token at [api.up.com.au](https://api.up.com.au/getting_started). This is
   what lets Uppies read your account.
3. Open Uppies and paste the token in. Tick **Remember on this PC** (or **this Mac**) if you don't
   want to paste it again next time.

Just want a look first? Choose **Explore with sample data** and you can try everything with a
made-up account, without connecting to Up at all.

Windows might say it "protected your PC" the first time you run the installer. That's because
Uppies is new and isn't code-signed yet. Click **More info**, then **Run anyway**.

Each download has a `.sha256` file next to it on the release page, holding its SHA-256 checksum.
To check your download is exactly the one released, compare that with what
`Get-FileHash Uppies-1.0.0-setup.exe` prints in PowerShell, or `shasum -a 256 Uppies-1.0.0-mac.dmg`
in the Mac's Terminal.

## Your money and your privacy

Uppies can't move money. Up's API doesn't allow it, so the most Uppies can change is a
transaction's category or tags.

Your token is only ever sent to Up (`api.up.com.au`). If you ask Uppies to remember it, it's
stored encrypted so that only your user account on your computer can read it. On Windows that's
done by Windows itself; on a Mac, the key is kept in your Keychain.

To open quickly, Uppies keeps a copy of your transactions on your computer, in
`%APPDATA%\Uppies` on Windows or `~/Library/Application Support/Uppies` on a Mac. That copy is
encrypted too, and only opens with your user account and your token. If the file has been
tampered with or damaged, Uppies throws it away and downloads your data again.

Each time Uppies opens, it shows your saved data straight away and then asks Up for anything
recent. Up can't say which older transactions have changed, so once a week Uppies quietly
rechecks your whole history. That way a category you changed in the Up app still shows up.

You're in control of the local copy. **Settings → Data** shows how big it is, lets you delete
it, and can turn it off altogether. Payments you've hidden on the Recurring page are kept
separately, so deleting the copy doesn't bring them back.

If you think your token has leaked, revoke it at
[api.up.com.au](https://api.up.com.au/getting_started) and make a new one.

## Keyboard shortcuts

| Keys                      | What they do                                          |
|---------------------------|-------------------------------------------------------|
| Ctrl+1 to Ctrl+8, Ctrl+Tab | Switch page                                          |
| / or Ctrl+F               | Search transactions                                   |
| F5 or Ctrl+R              | Refresh from Up                                       |
| Arrow keys, PgUp, PgDn, Home, End | Move through a table                          |
| Ctrl+click, Shift+click   | Select several transactions or accounts               |
| Ctrl+P                    | Save the selected transaction as a PDF                |
| Ctrl+Z                    | Undo your last category or tag change                 |
| Esc                       | Close a menu, clear the search or close the details panel |
| Tab, Shift+Tab            | Move between controls (Enter or Space to press one)   |

On a Mac, use Cmd (⌘) wherever it says Ctrl, except for Ctrl+Tab.

## Uninstalling

On Windows, uninstall Uppies from **Settings → Apps**. It will ask whether to delete your saved
token and data as well. Say no if you plan to install it again and want to pick up where you
left off.

On a Mac, drag Uppies to the Bin. Your data stays in `~/Library/Application Support/Uppies`
until you delete that folder (or use **Delete local data** in Settings first).

## Found a problem?

Please [open an issue](https://github.com/rubenbala/uppies/issues). Never include your token, any
of Uppies' data files, or screenshots of your real account. Sample data mode is perfect
for screenshots. If it's a security problem, please report it privately instead (see
[SECURITY.md](SECURITY.md)).

## Building from source

Uppies is written in a beta programming language by Jonathan Blow, commonly known as "JAI". The compiler is in closed beta, so you'll need
beta access and `jai` on your PATH.

```bash
jai build.jai                 # debug build: bin/uppies.exe
jai build.jai - release       # optimised build, no console window
jai build.jai - run           # build, then launch
jai build.jai - bundle        # release build plus the installer: bin/Uppies-<version>-setup.exe
```

`bundle` also writes a `.sha256` checksum file next to what it makes. Upload both to the release.

Making the installer needs [Inno Setup 6](https://jrsoftware.org/isinfo.php). The build finds it
where it normally installs, or you can set `UPPIES_ISCC` to the path of its `ISCC.exe`. The
installer script is [installer/uppies.iss](installer/uppies.iss).

### macOS

The same commands build a Metal version for Apple silicon Macs running macOS 13 or newer. You'll
need Xcode, plus its Metal Toolchain (install it once with
`xcodebuild -downloadComponent MetalToolchain`).

```bash
jai build.jai - bundle   # also makes bin/Uppies.app, and the disk image bin/Uppies-<version>-mac.dmg
```

The disk image holds `Uppies.app` next to a shortcut to Applications, so people can drag it in.

`Uppies.app` keeps its key in your login Keychain and its data in
`~/Library/Application Support/Uppies`. Because it's signed ad hoc, macOS treats every rebuild as
a new app and asks once whether it may use the key. Set `UPPIES_SIGN_IDENTITY` to a code-signing
identity to avoid that. The bundle only runs on the Mac that built it; sharing it needs a
Developer ID signature and notarisation.

Development builds (debug builds, and release builds run from `bin/`) don't use the Keychain.
They keep their key in a file in `~/Library/Application Support/Uppies Dev`, separate from the
real app's data. That's less secure, so use `Uppies.app` for your real account.

### Command-line options

These are mostly for testing. Scripted and timed runs never touch your saved token or settings.
`-selftest` and `-script` are left out of bundled builds (the installer and `Uppies.app`), so
they only work in builds made without `bundle`.

| Option                  | Effect                                                      |
|-------------------------|-------------------------------------------------------------|
| `-demo`                 | Start with sample data                                      |
| `-selftest`             | Run the built-in checks and exit (0 means they passed)      |
| `-size 1440x900`        | Set the starting window size                                |
| `-page spending`        | Open on a particular page                                   |
| `-script "steps"`       | Drive the app off screen, saving PNGs and PDFs (see `src/app/script.jai`) |
| `-hidden -quit-after N` | Run off screen for N seconds, then report frames drawn and CPU time |
| `-continuous`           | Draw every frame, for benchmarking                          |

### Fonts

Uppies uses fonts that come with Windows: Segoe UI for text, Cascadia Mono (or Consolas) for IDs
and times, Bahnschrift for the big numbers and Segoe MDL2 Assets for icons. To use your own,
put `ui-regular.ttf`, `ui-semibold.ttf`, `ui-light.ttf`, `ui-mono.ttf` or `ui-numeric.ttf` in
`data/fonts/`.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how it all fits together.

## License

[MIT](LICENSE) © 2026 Ruben Bala. Third-party components are listed in
[THIRD_PARTY.md](THIRD_PARTY.md).
