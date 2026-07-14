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

    /// 주입 직전에 '사용자가 계속 타이핑했는지'를 확인하기 위해 기다리는 시간.
    ///
    /// 가드는 이 창이 빠른 타이피스트의 키 간격(대략 100ms)보다 길 때만 의미가 있다.
    /// 짧으면 사용자의 다음 글자가 '확인한 뒤, 백스페이스가 나가기 전'에 도착해서
    /// 가드를 그대로 통과한다 — 잡으려던 바로 그 경합이 남는다.
    ///
    /// 대가는 정상 확장이 이만큼 늦어지는 것뿐이다. 종결자를 치고 잠시 멈춘 사용자는
    /// 100ms 남짓 늦게 확장을 받는다. 그 대신, 계속 타이핑한 사용자는 자기 글자를
    /// 잃지 않는다. 두 손실의 무게는 비교가 되지 않는다.
    static let quiescenceSettle: Double = 0.12

    /// Full expansion: delete `backspaces` characters, paste `text`, position
    /// the cursor, then press any trailing keys. Runs asynchronously.
    ///
    /// `expectedPID` is the app that had focus when the abbreviation matched.
    /// If focus has since moved, the expansion is dropped rather than typed into
    /// whatever happens to be frontmost now.
    ///
    /// `quiescence`는 '지금 지워도 되는가'를 마지막으로 되묻는 콜백이다. 이벤트 탭이
    /// `.listenOnly`라 사용자의 키는 우리보다 먼저 앱에 도착한다 — 매치 이후 사용자가
    /// 타이핑을 이어갔다면 백스페이스는 약어가 아니라 그 뒤에 새로 들어온 글자를 지운다.
    /// 그래서 첫 백스페이스가 나가기 '직전'에 물어보고, 아니라면 아무것도 하지 않는다:
    /// 지우지도, 붙여넣지도, 클립보드를 건드리지도 않는다.
    static func expand(
        backspaces: Int,
        text: String,
        cursorOffsetFromEnd: Int = 0,
        trailingKeys: [String] = [],
        restoreClipboardAfter: Double = 0.35,
        playSound: Bool = false,
        expectedPID: pid_t? = nil,
        quiescence: (() -> ExpansionDecision)? = nil,
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

            // 마지막 관문. 여기 아래로는 되돌릴 수 없는 키가 나간다.
            //
            // 확인은 반드시 '여기'여야 한다. 비동기 블록 맨 위에서 한 번 보고 마는 것으로는
            // 부족하다 — 그 아래에 있는 sleep들(정착 40ms, 붙여넣기 전 80ms, …) 동안
            // 사용자의 다음 글자가 얼마든지 도착할 수 있기 때문이다. frontmostPID()가
            // 메인 큐를 동기로 기다리는 것도 마찬가지 이유로 이 앞에 둔다.
            if let quiescence {
                usleep(useconds_t(quiescenceSettle * 1_000_000))
                if case .abort(let typedAhead) = quiescence() {
                    // 확장을 통째로 버린다. 사용자는 확장을 못 볼 뿐이고, 친 글자는
                    // 그대로 남는다. 약어를 다시 치고 잠깐 멈추면 확장된다.
                    Log.write("expansion cancelled — user kept typing (\(typedAhead) keys arrived after the match)")
                    return
                }
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
