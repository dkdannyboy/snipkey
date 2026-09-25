# SnipKey for Windows

A port of SnipKey to Windows 10 and 11. It follows the same expansion rules as the Mac app and reads the same library file, so one snippet library can serve both.

> **Status: preview.** The core logic runs 65 unit tests, all passing on every build, and CI launches the packaged `.exe` on a real Windows runner. The keyboard hook and text injection have not been through a long hands-on test yet. Please report anything that misbehaves.

## Install

1. Download `SnipKey.exe` from the **Windows** workflow artifacts or a release.
2. Run it. It needs no installer and no administrator rights. SnipKey lives in the notification area (the system tray).
3. Type `;hello` anywhere.

Windows SmartScreen may warn about an unsigned app the first time you run it. Choose **More info → Run anyway**.

## What works

| Feature | Notes |
|---|---|
| Abbreviation expansion | Same rules as the Mac. `;sig` expands at once. `sig` waits for a space or punctuation mark. Enter and Tab never trigger an expansion. |
| Fill-in forms | `%filltext%`, `%fillarea%`, `%fillpopup%` and `%fillpart%`, including nested optional sections and fields that share a name |
| Macros | `%clipboard`, `%|` (cursor position), `%key:enter%`, `%date:yyyy-MM-dd%`, `%date:+1d:…%` and the TextExpander date codes (`%Y`, `%B`, `%@+1D`, …) |
| Nested snippets | `%snippet:;abbr%`, up to 10 levels deep |
| Adapt case | `;Sig` → "Best regards", `;SIG` → "BEST REGARDS" |
| Undo with Backspace | Pressing Backspace right after an expansion puts back the abbreviation you typed |
| Excluded programs | Available from the tray menu ("Don't expand in …") or in Settings |
| Search palette | **Ctrl+Shift+Space** by default. You can change it in Settings. |
| Shared library with a Mac | Point both computers at one file in a synced folder (see below) |
| UI languages | English, 한국어 and 日本語 |

## Sharing a library with a Mac

SnipKey runs no sync service of its own. Instead, both computers use the same file in a folder that your cloud service already keeps in sync, such as iCloud Drive for Windows, Dropbox or OneDrive.

- **On the Mac:** go to Settings → Sync → **Save Snippets As…** and choose a synced folder. This creates `SnipKey-snippets.json`.
- **On Windows:** go to Settings → **Link to Library…** and pick that file.

The rules that protect your data are the same on both platforms:
- If another computer changed the file after SnipKey last read it, SnipKey won't overwrite it. When you have unsaved edits at that moment, your version is kept next to the file as `… (conflict …).json`.
- Before each overwrite, the previous contents are kept as `.bak`.
- If SnipKey can't read the library, it saves a copy and stops saving until the problem is fixed.
- Settings that only the Mac uses, such as hotkey macros and Mac key codes, are kept unchanged.

On Windows, turning expansion on or off and the list of excluded programs are stored per computer in `%APPDATA%\SnipKey\windows-settings.json`. They do not sync.

## Known limitations

- **Programs running as administrator.** Windows doesn't let a normal program type into an elevated window, and gives no error when this happens. SnipKey detects these windows, skips them, and tells you once per program. To expand in such a program, run SnipKey as administrator too.
- **IMEs in native mode (한글, Japanese kana, Chinese).** SnipKey doesn't expand while an input method is composing, because it can't tell how many characters are on screen. Type abbreviations in English mode, or use the search palette. On the Mac, SnipKey can match physical keys while Korean input is on; bringing that to Windows is planned.
- **Held modifier keys.** If Shift, Ctrl, Alt or Win is still held half a second after the trigger, SnipKey skips the expansion rather than send keys that would mean something else (Shift+← selects text).
- **TextExpander import.** On Windows, SnipKey imports SnipKey JSON (Settings → Import). To bring over a TextExpander library, import it on a Mac first, or link to the shared library file.
- **Rich text.** Rich-text snippets expand as plain text, the same as on the Mac.

## Build

The project needs the .NET 8 SDK. It builds on Windows, macOS and Linux. The app itself runs only on Windows.

```bash
cd windows
dotnet test tests/SnipKey.Core.Tests   # core logic tests (run on any OS)
./scripts/publish.sh                   # → dist/SnipKey.exe, a self-contained single file
dist/SnipKey.exe --selfcheck           # on Windows: smoke test without UI
```

| Project | What it contains |
|---|---|
| `src/SnipKey.Core` | Models, store file I/O, the macro parser, the matcher, search, and the typing buffer. It has no UI and is testable anywhere. |
| `src/SnipKey.Windows` | The tray app: keyboard and mouse hooks, text injection, and the forms (WinForms) |
| `tests/SnipKey.Core.Tests` | xUnit tests. The same cases as the Swift tests, plus a round trip of a `store.json` written by the Mac app. |

Logs are written to `%APPDATA%\SnipKey\SnipKey.log`. Snippet contents never go into the log.
