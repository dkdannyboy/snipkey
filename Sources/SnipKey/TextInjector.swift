import AppKit
import Carbon.HIToolbox
import SnipKeyKit

/// Posts synthetic keyboard events: deletes the typed abbreviation and pastes
/// the expansion. All events are tagged so the expansion engine ignores them.
enum TextInjector {

    /// Marker attached to every synthetic event we post.
    static let magicUserData: Int64 = 0x534E_4950 // "SNIP"

    private static let queue = DispatchQueue(label: "snipkey.injector")

    private static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = magicUserData
        return source
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Sends a real ⌘V: the Command key is physically pressed and released
    /// around the V.
    ///
    /// Merely setting `.maskCommand` on the V event is not enough. Plenty of
    /// apps — and every input method — track modifier state from the Command
    /// key's own down/up events, so a V that merely *claims* to be modified gets
    /// treated as a plain keystroke and the user sees a literal "v" instead of
    /// their snippet.
    private static func postCommandV(source: CGEventSource?) {
        let command = CGKeyCode(kVK_Command)

        if let down = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        usleep(15_000)

        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
        usleep(15_000)

        if let up = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }

    private static func keyCode(forName name: String) -> CGKeyCode? {
        switch name {
        case "enter", "return": return CGKeyCode(kVK_Return)
        case "tab": return CGKeyCode(kVK_Tab)
        case "escape", "esc": return CGKeyCode(kVK_Escape)
        case "space": return CGKeyCode(kVK_Space)
        default: return nil
        }
    }

    /// The app that was frontmost when the abbreviation was typed. Expansion is
    /// abandoned if focus moved elsewhere in the meantime, so we never backspace
    /// over and paste into an unrelated app.
    private static func frontmostPID() -> pid_t? {
        if Thread.isMainThread {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        return DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    /// Full expansion: delete `backspaces` characters, paste `text`, position
    /// the cursor, then press any trailing keys. Runs asynchronously.
    ///
    /// `expectedPID` is the app that had focus when the abbreviation matched.
    /// If focus has since moved, the expansion is dropped rather than typed into
    /// whatever happens to be frontmost now.
    static func expand(
        backspaces: Int,
        text: String,
        cursorOffsetFromEnd: Int = 0,
        trailingKeys: [String] = [],
        restoreClipboardAfter: Double = 0.35,
        playSound: Bool = false,
        expectedPID: pid_t? = nil,
        completion: (() -> Void)? = nil
    ) {
        queue.async {
            let source = makeSource()

            // Give the host app a moment to finish processing the trigger key.
            usleep(40_000)

            if let expectedPID, frontmostPID() != expectedPID {
                Log.write("expansion cancelled — focus left the original app")
                return
            }

            for _ in 0..<backspaces {
                postKey(CGKeyCode(kVK_Delete), source: source)
                usleep(4_000)
            }
            usleep(30_000)

            let saved = snapshotClipboard()
            let pastedAt = Date()
            pasteText(text, source: source)

            if cursorOffsetFromEnd > 0 {
                usleep(120_000)
                for _ in 0..<cursorOffsetFromEnd {
                    postKey(CGKeyCode(kVK_LeftArrow), source: source)
                    usleep(3_000)
                }
            }

            for name in trailingKeys {
                if let code = keyCode(forName: name) {
                    usleep(120_000)
                    postKey(code, source: source)
                }
            }

            restoreClipboard(saved, ifStillHolding: text, pastedAt: pastedAt, minimumDelay: restoreClipboardAfter)

            Log.write("inject done (pasted \(text.count) chars)")
            if playSound {
                DispatchQueue.main.async { NSSound(named: "Pop")?.play() }
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    /// Pastes text at the cursor without deleting anything (hotkey macros).
    static func insertText(_ text: String, restoreClipboardAfter: Double = 0.35) {
        queue.async {
            let source = makeSource()
            let saved = snapshotClipboard()
            let pastedAt = Date()
            pasteText(text, source: source)
            restoreClipboard(saved, ifStillHolding: text, pastedAt: pastedAt, minimumDelay: restoreClipboardAfter)
        }
    }

    // MARK: - Clipboard
    //
    // Snapshot, paste, and restore all run to completion inside one block on the
    // serial injector queue. That ordering is the whole point: if the restore
    // were merely *scheduled*, a second expansion arriving before it ran would
    // snapshot the first snippet as the "original" clipboard, and the user would
    // be left with a snippet on their clipboard instead of what they had copied.

    private static func snapshotClipboard() -> [[String: Data]] {
        dispatchPrecondition(condition: .onQueue(queue))
        var saved: [[String: Data]] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            saved.append(entry)
        }
        return saved
    }

    private static func pasteText(_ text: String, source: CGEventSource?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard server time to publish the new contents before
        // the target app reads them.
        usleep(80_000)
        postCommandV(source: source)
    }

    /// Waits until the host app has had time to consume the paste, then puts the
    /// user's clipboard back — unless they copied something new in the meantime.
    private static func restoreClipboard(
        _ saved: [[String: Data]],
        ifStillHolding text: String,
        pastedAt: Date,
        minimumDelay: Double
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let elapsed = Date().timeIntervalSince(pastedAt)
        let remaining = max(0.2, minimumDelay) - elapsed
        if remaining > 0 {
            usleep(useconds_t(remaining * 1_000_000))
        }

        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) == text else { return }

        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        for entry in saved {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            items.append(item)
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
