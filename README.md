# SnipKey

A free, open-source text expander and hotkey macro tool for macOS — built as a
drop-in replacement for TextExpander (with a one-click migration path) plus the
everyday parts of Keyboard Maestro.

Native Swift, Apple Silicon, no subscription, no account, no network access.

SnipKey lives in the menu bar (the ⚡ icon) and also keeps a Dock icon. It began
as a menu-bar-only app, but macOS will not let an accessory app become active,
so its window opened without keyboard focus — ⌘N went to whatever app was in
front, and ⌘C/⌘V did not work inside the snippet editor. A Dock icon is a small
price for a window that behaves like every other window on the Mac.

---

## What it does

**Text expansion.** Type an abbreviation in any app and SnipKey replaces it with
the full text. `;sig` becomes your signature; `;addr` becomes your address.

**Search anywhere (⌘/).** Cannot remember an abbreviation? Press ⌘/ while typing
in any app, search your whole library by abbreviation, label, or content, and
press Return to expand the one you want. This is what makes a library of
hundreds of snippets actually usable.

**TextExpander migration.** Point SnipKey at your existing TextExpander data and
it imports every group, abbreviation, and snippet — including fill-ins, nested
snippets, and clipboard macros. Nothing to retype.

**Hotkey macros.** Global shortcuts that insert text, run a shell script, run
AppleScript, open an app, or open a URL. The Keyboard Maestro basics, minus the
price tag.

**Fill-in forms.** A snippet can pause and ask you for a name, an amount, or a
choice from a list, then assemble the final text.

---

## Install

Requires macOS 13 or later.

```bash
git clone https://github.com/dkdannyboy/snipkey.git
cd snipkey
./scripts/build-app.sh --install
open /Applications/SnipKey.app
```

The Setup Assistant then walks you through the one permission SnipKey needs and
helps you bring your snippets in (or start fresh with samples).

### The Accessibility permission

macOS requires **Accessibility** access for any app that watches what you type
and types on your behalf. There is no way around it — TextExpander, Keyboard
Maestro, and every other expander need the same thing.

System Settings → Privacy & Security → Accessibility → turn on **SnipKey**.

SnipKey has no networking code at all. Nothing you type leaves your Mac.

> **If expansion stops working after you update SnipKey:** macOS ties the grant
> to the app's code signature. A new build has a new signature, so the switch
> stays on while macOS quietly ignores it. Open SnipKey's Settings and use
> **Clear Permission and Re-grant** — or run
> `tccutil reset Accessibility io.snipkey.mac` and switch it back on.

---

## Migrating from TextExpander

SnipKey reads TextExpander 4/5 data directly. On first launch it looks in the
usual places:

- `~/Library/Mobile Documents/com~apple~CloudDocs/TextExpander/Settings.textexpandersettings` (iCloud)
- `~/Library/Application Support/TextExpander/Settings.textexpandersettings`
- `~/Dropbox/TextExpander/Settings.textexpandersettings`
- the newest backup in `~/Library/Application Support/TextExpander/Backups/`

If your data lives somewhere else, use **Import from folder…** and pick the
`.textexpandersettings` or `.textexpanderbackup` folder.

You can also migrate from the command line:

```bash
/Applications/SnipKey.app/Contents/MacOS/SnipKey --import-te /path/to/data.textexpanderbackup
```

Formatted (rich text) snippets are imported as plain text; everything else comes
across as-is.

---

## Macro reference

SnipKey uses TextExpander's macro syntax, so imported snippets keep working.

| Macro | What it does |
|---|---|
| `%filltext:name=X%` | Asks for a single line of text |
| `%filltext:name=X:default=Y%` | …with a default value |
| `%fillarea:name=X%` | Asks for multi-line text |
| `%fillpopup:name=X:one:two:default=one%` | Asks you to pick from a list |
| `%fillpart:name=X:default=yes%` … `%fillpartend%` | An optional section you can toggle off |
| `%snippet:;abbrev%` | Inserts another snippet (nested, up to 10 deep) |
| `%clipboard` | Inserts the current clipboard text |
| `%date:yyyy-MM-dd%` | Inserts the date or time in any `DateFormatter` format |
| `%\|` | Leaves the cursor here after expanding |
| `%key:enter%` | Presses a key after expanding (`enter`, `tab`, `escape`, `space`) |

Percent signs that aren't macros — like the `%EC%9D%B4` in an encoded URL — are
left alone.

---

## Keyboard shortcuts

| Shortcut | Where | What |
|---|---|---|
| `⌘/` | Any app | Search snippets and expand the one you pick |
| `↑` `↓` `↩` `⌘1`–`⌘9` `esc` | Search palette | Navigate, expand, jump, close |
| `⌘F` | SnipKey window | Focus the search field |
| `⌘N` | SnipKey window | New snippet (scrolls to it and highlights it) |

The search shortcut can be changed or turned off in Settings.

---

## Hotkey macros

| Action | Argument |
|---|---|
| Insert Text | The text to paste (macros above work here too) |
| Run Shell Script | Script source, run with `/bin/zsh -lc` |
| Run AppleScript | AppleScript source |
| Open URL | A URL or a file path |
| Open Application | An app name (`Safari`) or a full path |

Set the shortcut by clicking the hotkey field and pressing the combination. At
least one modifier key is required.

Enable **Launch SnipKey at login** in Settings so your macros are always ready,
or run:

```bash
/Applications/SnipKey.app/Contents/MacOS/SnipKey --enable-login-item
```

---

## Where your data lives

| What | Path |
|---|---|
| Snippets, macros, settings | `~/Library/Application Support/SnipKey/store.json` |
| Troubleshooting log | `~/Library/Logs/SnipKey.log` |

`store.json` is plain JSON — back it up, sync it, or edit it by hand. Settings
also has an **Export snippets…** button.

If SnipKey ever finds that file but cannot read it — a bad sync, a half-written
file, a hand edit gone wrong — it does **not** start over on top of it. It keeps
a timestamped copy next to the original, refuses to save anything, and asks you
in Settings whether to retry the file or start fresh. Your snippets are never
overwritten by a failed read.

---

## Development

```bash
swift build          # build
swift test           # run the unit tests (parser + importer + matcher)
./scripts/build-app.sh           # build dist/SnipKey.app
./scripts/build-app.sh --install # …and install it to /Applications
```

The code is split into two targets:

- `SnipKeyKit` — models, JSON store, TextExpander importer, macro parser. No UI,
  fully unit-tested.
- `SnipKey` — the menu bar app: the CGEvent tap that watches typing, the
  synthetic-keystroke injector, the Carbon hotkey manager, and the SwiftUI
  windows.

During development, every rebuild changes the ad-hoc code signature and macOS
drops the Accessibility grant. `./scripts/dev-grant-accessibility.sh` clears the
stale entry, re-approves the app, and verifies the event tap actually came back
up.

---

## License

MIT. See [LICENSE](LICENSE).
