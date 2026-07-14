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

An abbreviation that starts with punctuation — `;sig`, `/addr`, `,date` — expands
the moment you finish typing it. The punctuation makes it unambiguous: no real
word starts that way.

A bare-word abbreviation like `sig` waits for you to type a terminator (a space,
a period, any non-word character) before it expands. It has to. `sig` is the
first three letters of `signal`, `sign`, and `signature`, so expanding the instant
you type it would make those words impossible to write — SnipKey would eat them
mid-keystroke. Type `sig ` and you get your signature followed by the space, right
where you put it. Punctuation-prefixed abbreviations are the ones to reach for
when you want expansion the moment you stop typing.

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

Download `SnipKey.dmg` from the [latest release][releases], open it, and drag
SnipKey to Applications. The disk image is signed and notarized by Apple, so it
opens without a Gatekeeper warning.

[releases]: https://github.com/dkdannyboy/snipkey/releases

Or build it yourself:

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

> **If expansion stops working after you rebuild SnipKey:** macOS ties the grant
> to the app's code signature. Released builds and builds signed with a real
> certificate keep the grant across updates, because macOS identifies them by
> bundle ID and team ID. But if you build on a Mac with no signing certificate
> at all, the build is signed ad-hoc and macOS identifies it by code hash alone
> — so every rebuild looks like a brand new app, and the switch stays on while
> macOS quietly ignores it. Open SnipKey's Settings and use **Clear Permission
> and Re-grant**, or run `tccutil reset Accessibility io.snipkey.mac` and switch
> it back on. To avoid this entirely, sign in to Xcode with any Apple ID — even
> a free one issues a certificate, and `build-app.sh` will pick it up
> automatically. See [Development](#development).

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
./scripts/release.sh             # signed + notarized dist/SnipKey-<version>.dmg
```

The code is split into two targets:

- `SnipKeyKit` — models, JSON store, TextExpander importer, macro parser. No UI,
  fully unit-tested.
- `SnipKey` — the menu bar app: the CGEvent tap that watches typing, the
  synthetic-keystroke injector, the Carbon hotkey manager, and the SwiftUI
  windows.

### Code signing

`build-app.sh` picks the best certificate it can find in your keychain and tells
you which one it used:

| Certificate in keychain | Signature | Survives rebuild | Distributable |
| --- | --- | --- | --- |
| `Developer ID Application` | Hardened runtime + trusted timestamp | Yes | Yes — this is what releases are built with |
| `Apple Development` | Hardened runtime | Yes | No — runs only on your own Macs |
| none | Ad-hoc | **No** | No |

The distinction that matters day to day is the middle column. macOS records the
Accessibility grant against a *designated requirement*. For a properly signed
app that requirement is "bundle ID `io.snipkey.mac`, team ID `36VF39Z75X`",
which a rebuild does not change. For an ad-hoc build there is no team ID, so the
requirement collapses to the raw code hash — and that changes every single
build, which is why the grant evaporates.

So if you are hacking on SnipKey, sign in to Xcode with an Apple ID (free is
fine) and let it issue you an `Apple Development` certificate. The grant then
stops disappearing. If you are stuck without one,
`./scripts/dev-grant-accessibility.sh` clears the stale TCC entry, re-approves
the app, and verifies the event tap actually came back up.

Override the choice with `SNIPKEY_SIGN_ID` if you need a specific certificate:

```bash
SNIPKEY_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

### Cutting a release

`./scripts/release.sh` produces a signed, notarized `dist/SnipKey-<version>.dmg`
that opens on any Mac with no Gatekeeper warning. It needs two things:

1. A `Developer ID Application` certificate — which requires a paid Apple
   Developer Program membership. Issue it from Xcode → Settings → Accounts →
   Manage Certificates → **+** → Developer ID Application. If you already have
   one on another Mac, export it from Keychain Access *with its private key* as
   a `.p12` and open that file on this Mac.

2. Notarization credentials, stored once in your keychain:

   ```bash
   xcrun notarytool store-credentials snipkey-notary \
     --apple-id "you@example.com" \
     --team-id "36VF39Z75X" \
     --password "<app-specific password>"
   ```

   The password is an app-specific password from appleid.apple.com → Sign-In and
   Security → App-Specific Passwords. Not your Apple ID password.

The script refuses to run with a clear explanation if either is missing, so it
will not hand you a half-signed build. It signs the app, sends it to Apple for
notarization, staples the ticket to the app *and* to the disk image, and
verifies the result with `spctl` before declaring success.

---

## License

MIT. See [LICENSE](LICENSE).
