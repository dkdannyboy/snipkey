<div align="center">

# ⚡ SnipKey

**A free, open-source text expander for macOS — a drop-in replacement for TextExpander.**

Native Swift · Apple Silicon · no subscription · no account · no network access

[![Release](https://img.shields.io/github/v/release/dkdannyboy/snipkey?color=brightgreen)](https://github.com/dkdannyboy/snipkey/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/dkdannyboy/snipkey/total)](https://github.com/dkdannyboy/snipkey/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/dkdannyboy/snipkey/releases/latest)
[![Made with Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)](https://swift.org)

**English** · [한국어](README.ko.md) · [日本語](README.ja.md)

<img src="docs/images/snippets.png" width="720" alt="SnipKey snippet library">

</div>

---

Type an abbreviation in any app and SnipKey replaces it with the full text. `;sig`
becomes your signature, `;addr` becomes your address. It lives in the menu bar,
imports your TextExpander library in one click, and never sends a keystroke off
your Mac.

## Features

- **Text expansion everywhere.** Works in every app. `;sig` → your signature.
- **Search anywhere (⌘/).** Forgot an abbreviation? Search your whole library by
  abbreviation, label, or content from inside any app, and press Return to expand.
- **TextExpander migration.** Imports every group, abbreviation, and snippet —
  including fill-ins, nested snippets, and clipboard macros. Nothing to retype.
- **Fill-in forms.** A snippet can pause and ask you for a name, an amount, or a
  choice from a list, then assemble the final text.
- **Multi-Mac sync.** Keep the same library on several Macs through iCloud Drive
  or any sync folder — with guardrails that refuse to lose your snippets.
- **Three languages.** English, 한국어, and 日本語, switchable instantly in Settings.
- **Private by design.** No account, no telemetry, no network code at all.

## Install

Requires macOS 13 or later.

**Download:** grab `SnipKey.dmg` from the [latest release][releases], open it, and
drag SnipKey to Applications. The disk image is signed and notarized by Apple, so
it opens without a Gatekeeper warning.

**Homebrew:**

```bash
brew tap dkdannyboy/tap
brew trust dkdannyboy/tap      # Homebrew asks you to vouch for third-party taps
brew install --cask snipkey
```

Upgrade later with `brew upgrade --cask snipkey`.

On first launch, the Setup Assistant walks you through the one permission SnipKey
needs — **Accessibility** — which every text expander requires to see what you type
and type the replacement back. Nothing you type leaves your Mac.

[releases]: https://github.com/dkdannyboy/snipkey/releases

## How expansion works

An abbreviation that starts with punctuation — `;sig`, `/addr`, `,date` — expands
the moment you finish typing it. The punctuation makes it unambiguous.

A bare-word abbreviation like `sig` waits for a terminator (a space, a period, any
non-word character) before it expands. It has to: `sig` is the first three letters
of `signal` and `signature`, so expanding instantly would make those words
impossible to type. Type `sig ` and you get your signature followed by the space.

**Return and Tab do not terminate a bare-word abbreviation** — on purpose. SnipKey
watches keystrokes without swallowing them, so by the time it could act, the key has
already reached the app, and Return and Tab *do things*: Return sends the message in
Slack, Tab moves to the next field. Expanding in the wrong place is worse than not
expanding. Finish with a space or punctuation, or use a `;sig`-style abbreviation.

## Multi-Mac sync

SnipKey doesn't run its own sync service. Point it at a file inside a folder your
cloud service already syncs (iCloud Drive, Dropbox, …), and the cloud does the
syncing. In **Settings → Sync**:

- **Save Snippets As…** — on your first Mac, copy your library into a synced folder.
- **Link to Snippets…** — on your second Mac, point at that same file.
- **Don't Sync** — go back to a local-only library.

A shared library is easy to destroy — two Macs writing at once, a not-yet-downloaded
iCloud placeholder, a switch that half-finishes. SnipKey refuses to be the one that
loses your snippets: it backs up before overwriting, reloads instead of clobbering
when the file changes underneath it, and never switches locations unless the new
library loaded cleanly.

## Migrating from TextExpander

SnipKey reads TextExpander 4/5 data directly. On first launch it looks in the usual
places (iCloud, Application Support, Dropbox, the newest local backup). If your data
lives elsewhere, use **Settings → Data → Import from folder…** and pick the
`.textexpandersettings` or `.textexpanderbackup` folder.

Formatted (rich text) snippets are imported as plain text; everything else comes
across as-is.

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
| <code>%&#124;</code> | Leaves the cursor here after expanding |
| `%key:enter%` | Presses a key after expanding (`enter`, `tab`, `escape`, `space`) |

## Keyboard shortcuts

| Shortcut | Where | What |
|---|---|---|
| `⌘/` | Any app | Search snippets and expand the one you pick |
| `⌘,` | Any window | Open Settings |
| `⌘N` | SnipKey window | New snippet |
| `⌘F` | SnipKey window | Focus the search field |

## Where your data lives

| What | Path |
|---|---|
| Snippets and settings | `~/Library/Application Support/SnipKey/store.json` |
| Troubleshooting log | `~/Library/Logs/SnipKey.log` |

`store.json` is plain JSON. If SnipKey ever finds that file but cannot read it, it
does **not** start over on top of it — it keeps a timestamped copy, refuses to save,
and asks you what to do. Your snippets are never overwritten by a failed read.

## Contributing

Pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) — especially the list
of behaviours that look like bugs but are deliberate.

```bash
git clone https://github.com/dkdannyboy/snipkey.git
cd snipkey
swift test                       # run the unit tests
./scripts/build-app.sh --install # build and install to /Applications
```

## License

MIT. See [LICENSE](LICENSE).
