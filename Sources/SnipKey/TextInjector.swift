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

    private static func keyCode(forName name: String) -> CGKeyCode? {
        switch name {
        case "enter", "return": return CGKeyCode(kVK_Return)
        case "tab": return CGKeyCode(kVK_Tab)
        case "escape", "esc": return CGKeyCode(kVK_Escape)
        case "space": return CGKeyCode(kVK_Space)
        default: return nil
        }
    }

    /// Full expansion: delete `backspaces` characters, paste `text`, position
    /// the cursor, then press any trailing keys. Runs asynchronously.
    static func expand(
        backspaces: Int,
        text: String,
        cursorOffsetFromEnd: Int = 0,
        trailingKeys: [String] = [],
        restoreClipboardAfter: Double = 0.35,
        playSound: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        queue.async {
            let source = makeSource()

            // Give the host app a moment to finish processing the trigger key.
            usleep(40_000)

            for _ in 0..<backspaces {
                postKey(CGKeyCode(kVK_Delete), source: source)
                usleep(4_000)
            }
            usleep(30_000)

            insertViaPasteboard(text, source: source, restoreAfter: restoreClipboardAfter)

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
            insertViaPasteboard(text, source: source, restoreAfter: restoreClipboardAfter)
        }
    }

    /// Replaces the clipboard, sends Cmd+V, and restores the previous
    /// clipboard contents afterwards.
    private static func insertViaPasteboard(_ text: String, source: CGEventSource?, restoreAfter: Double) {
        let pasteboard = NSPasteboard.general

        // Snapshot current clipboard so it can be restored.
        var saved: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            saved.append(entry)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        usleep(60_000)
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)

        // Restore after the host app has consumed the paste.
        queue.asyncAfter(deadline: .now() + max(0.2, restoreAfter)) {
            let current = NSPasteboard.general
            guard current.string(forType: .string) == text else { return } // user copied something new
            current.clearContents()
            var items: [NSPasteboardItem] = []
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                items.append(item)
            }
            if !items.isEmpty {
                current.writeObjects(items)
            }
        }
    }
}
