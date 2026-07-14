import AppKit
import Carbon.HIToolbox
import SnipKeyKit

/// Watches global keystrokes with a CGEvent tap, matches typed abbreviations
/// against the store, and triggers expansion.
final class ExpansionEngine {
    private let store: Store
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private let maxBuffer = 64

    /// 사용자가 실제로 친 키의 수. 확장이 큐에 걸린 뒤에도 이 값이 움직였다면
    /// 그 확장은 이미 엉뚱한 자리를 지우게 된다 — 그래서 버린다.
    ///
    /// 합성 이벤트(우리가 쏜 백스페이스·⌘V)는 절대 세지 않는다. 세면 인젝터의 첫
    /// 백스페이스가 바로 그 확장을 스스로 취소해 버린다.
    private let keystrokes = KeystrokeCounter()
    /// The open fill-in panel, if any. Typing is ignored while it is on screen.
    /// Deriving suspension from the window itself means a panel that closes
    /// unexpectedly can never leave the engine permanently deaf.
    private weak var activePanel: NSWindow?
    private var isSuspended: Bool {
        guard let panel = activePanel else { return false }
        return panel.isVisible
    }

    var isRunning: Bool { eventTap != nil }

    init(store: Store) {
        self.store = store
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// After an app update the code signature changes, and macOS silently stops
    /// honoring the old Accessibility grant even though the toggle still looks
    /// on. Clearing SnipKey's own TCC entry lets the user grant it again.
    static func resetAccessibilityGrant() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()
    }

    /// Starts the event tap if accessibility permission has been granted.
    /// Safe to call repeatedly.
    func startIfPossible() {
        guard eventTap == nil, Self.hasAccessibilityPermission else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ExpansionEngine>.fromOpaque(refcon).takeUnretainedValue()
            engine.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("SnipKey: failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("engine started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that appear unresponsive — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("tap disabled (type=\(type.rawValue)) — re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Ignore our own synthetic events.
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicUserData {
            return
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            buffer = ""
            return
        }

        guard type == .keyDown else { return }

        // 여기가 '진짜 사용자 키'의 유일한 관문이다. 합성 이벤트는 위에서 걸러졌다.
        //
        // 버퍼를 비우는 키(Escape·화살표)와 수정자 조합(⌘V 붙여넣기)까지 전부 센다.
        // 그것들도 대상 앱의 텍스트나 커서를 움직이므로, 매치 이후에 들어왔다면
        // 백스페이스가 지울 자리는 이미 우리가 계산한 그 자리가 아니다.
        //
        // 패널(필인)이 떠 있는 동안의 키는 세지 않는다. 그 키는 패널로 들어가지 대상
        // 앱으로 가지 않아서, 지울 글자 수를 어긋나게 만들지 않는다. 여기서 세면
        // 필인 값을 입력한다는 이유만으로 모든 필인 확장이 취소된다.
        if !isSuspended {
            keystrokes.bump()
        }

        guard !isSuspended, store.settings.expansionEnabled else {
            buffer = ""
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch KeyClassifier.action(forKeyCode: keyCode) {
        case .deleteLast:
            if !buffer.isEmpty { buffer.removeLast() }
            return

        case .clearBuffer:
            buffer = ""
            return

        case .literal:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) else { return }

        // 스페이스나 구두점도 여기로 들어온다. 종결자 판정은 매처가 한다 —
        // 이 층은 '타이핑된 글자'와 '버퍼를 무효화하는 키'만 구분하면 된다.
        appendAndMatch(typed)
    }

    /// 버퍼에 글자를 붙이고 매칭을 시도한다. 매치되면 버퍼를 비우고 확장을 건다.
    private func appendAndMatch(_ typed: String) {
        buffer += typed
        if buffer.count > maxBuffer {
            buffer = String(buffer.suffix(maxBuffer))
        }

        if let match = store.matcher.match(buffer: buffer) {
            Log.write("matched '\(match.snippet.abbreviation)'")
            buffer = ""
            // 지금 이 순간의 키 카운터를 고정한다. 방금 친 종결자까지 포함된 값이다.
            // 이 뒤로 키가 하나라도 더 오면 확장은 버려진다.
            let quiescence = keystrokes.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.expand(match, quiescence: quiescence)
            }
        }
    }

    // MARK: - Expansion

    /// Expands a snippet the user chose from the inline-search palette. Nothing
    /// was typed, so nothing gets deleted — the text simply lands at the cursor
    /// in the app they were working in.
    func expandFromSearch(_ snippet: Snippet, into app: NSRunningApplication?) {
        // Let focus finish returning to the original app before typing into it.
        // 아무것도 타이핑되지 않았으므로 지울 것도, 되돌려 찍을 종결자도 없다.
        //
        // 지울 글자가 없으니 입력 정숙 가드도 걸지 않는다(quiescence: nil). 가드는
        // 백스페이스가 엉뚱한 글자를 먹는 것을 막는 장치인데, 여기엔 백스페이스가 없다.
        // 게다가 사용자는 방금 팔레트에 검색어를 타이핑했으므로 카운터는 반드시
        // 움직여 있다 — 가드를 걸면 팔레트 확장이 100% 취소된다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.expand(snippet, backspaces: 0, terminator: "", targetApp: app, quiescence: nil)
        }
    }

    /// 매처가 정한 대로 지우고 확장한다. 몇 글자를 지울지는 약어 길이가 아니라
    /// 매치가 알려준다 — 맨몸 약어는 종결자까지 함께 지웠다가 뒤에 다시 찍는다.
    private func expand(_ match: Store.Matcher.Match, quiescence: InputQuiescenceGuard) {
        // The app the abbreviation was typed into. Everything we inject has to
        // land there, not wherever focus drifts to while we work.
        expand(
            match.snippet,
            backspaces: match.backspaces,
            terminator: match.terminator,
            targetApp: NSWorkspace.shared.frontmostApplication,
            quiescence: quiescence
        )
    }

    private func expand(
        _ snippet: Snippet,
        backspaces: Int,
        terminator: String,
        targetApp: NSRunningApplication?,
        quiescence: InputQuiescenceGuard?
    ) {
        let resolved = MacroParser.resolveNested(snippet.content) { [weak self] abbrev in
            self?.store.snippet(forAbbreviation: abbrev)?.content
        }
        let tokens = MacroParser.parse(resolved)

        guard MacroParser.hasFillIns(tokens) else {
            inject(
                tokens: tokens,
                fillValues: [:],
                backspaces: backspaces,
                terminator: terminator,
                targetPID: targetApp?.processIdentifier,
                quiescence: quiescence
            )
            return
        }

        // 필인은 패널을 띄우고 사용자를 기다린다. 그 사이 카운터가 움직이는 것은
        // '정상'이므로 — 사용자가 필드에 값을 치니까 — 매치 시점의 가드 하나를
        // 주입 직전까지 그대로 들고 갈 수 없다. 대신 서로 다른 두 구간을 각각 지킨다.
        //
        //   구간 1 (매치 → 패널 표시): 키가 대상 앱으로 들어간다. 여기서 타이핑을
        //     이어갔다면 나중에 나갈 백스페이스는 이미 어긋난다. 그래서 패널을 띄우기
        //     '전'에 정착 시간만큼 기다렸다가 매치 시점 가드로 판정하고, 어긋났으면
        //     패널조차 띄우지 않는다. (띄워봐야 확인만 받고 취소할 확장이다.)
        //
        //   구간 2 (패널 닫힘 → 주입): 포커스가 대상 앱으로 돌아온 뒤다. 여기서는
        //     가드를 새로 뜬다. 패널에 친 글자는 대상 앱의 텍스트를 바꾸지 않았으므로
        //     지울 글자 수는 여전히 유효하다 — 매치 시점 값을 그대로 쓰면 필인 확장이
        //     전부 취소되고, 새로 뜨면 '포커스가 돌아온 뒤의 타이핑'만 정확히 잡는다.
        let show = { [weak self] in
            self?.showFillInPanel(
                snippet: snippet,
                tokens: tokens,
                backspaces: backspaces,
                terminator: terminator,
                targetApp: targetApp
            )
        }

        guard let quiescence, backspaces > 0 else {
            show()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + TextInjector.quiescenceSettle) { [weak self] in
            guard let self else { return }
            if case .abort(let typedAhead) = quiescence.decide(currentKeystrokes: self.keystrokes.current) {
                Log.write("expansion cancelled — user kept typing (\(typedAhead) keys arrived after the match) — fill-in panel not shown")
                return
            }
            show()
        }
    }

    private func showFillInPanel(
        snippet: Snippet,
        tokens: [MacroToken],
        backspaces: Int,
        terminator: String,
        targetApp: NSRunningApplication?
    ) {
        let panel = FillInPanel.present(
            title: snippet.displayTitle,
            fields: MacroParser.fillFields(in: tokens)
        ) { [weak self] values in
            guard let self else { return }
            self.activePanel = nil
            // Return focus to the app the user was typing in.
            targetApp?.activate()
            guard let values else {
                // Cancelled — leave the typed abbreviation in place.
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                // 가드를 '여기서' 새로 뜬다. 패널을 닫은 그 키(Return)까지 이미
                // 처리된 뒤다 — 이벤트 탭 콜백과 패널의 자체 키 처리는 둘 다 메인
                // 런루프를 타서 순서가 보장되지 않는다. 닫히는 순간에 스냅샷을 뜨면
                // 그 Return이 뒤늦게 카운트되어 멀쩡한 필인 확장을 취소할 수 있다.
                // 0.25초 뒤인 이 시점에는 그 경합이 남아 있지 않다.
                let quiescence = self.keystrokes.snapshot()
                self.inject(
                    tokens: tokens,
                    fillValues: values,
                    backspaces: backspaces,
                    terminator: terminator,
                    targetPID: targetApp?.processIdentifier,
                    quiescence: quiescence
                )
            }
        }
        activePanel = panel
        Log.write("fill panel presented (visible=\(panel.isVisible))")
    }

    private func inject(
        tokens: [MacroToken],
        fillValues: [Int: String],
        backspaces: Int,
        terminator: String,
        targetPID: pid_t?,
        quiescence: InputQuiescenceGuard?
    ) {
        Log.write("inject start (backspaces=\(backspaces))")
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let result = MacroParser.render(
            tokens: tokens,
            fillValues: fillValues,
            clipboard: clipboardText
        )

        // 종결자는 이미 사용자가 쳤고 백스페이스로 함께 지워졌다. 매크로·필인이
        // 모두 전개된 '뒤'에 다시 붙여야 사용자가 친 그 자리에 그대로 남는다.
        // 커서 매크로(%|%)가 있으면 그 위치가 밀리지 않도록 오프셋도 함께 민다.
        var text = result.text
        var cursorOffsetFromEnd = result.cursorOffsetFromEnd
        if !terminator.isEmpty {
            text += terminator
            if cursorOffsetFromEnd > 0 {
                cursorOffsetFromEnd += terminator.count
            }
        }

        // 지울 글자가 있을 때만 가드를 건다. 백스페이스가 없으면 파괴할 것도 없고
        // (팔레트 확장이 그렇다), 그때 가드를 걸면 정상 확장을 죽이기만 한다.
        let check: (() -> ExpansionDecision)?
        if let quiescence, backspaces > 0 {
            let counter = keystrokes
            check = { quiescence.decide(currentKeystrokes: counter.current) }
        } else {
            check = nil
        }

        TextInjector.expand(
            backspaces: backspaces,
            text: text,
            cursorOffsetFromEnd: cursorOffsetFromEnd,
            trailingKeys: result.trailingKeys,
            restoreClipboardAfter: store.settings.clipboardRestoreDelay,
            playSound: store.settings.playSoundOnExpand,
            expectedPID: targetPID,
            quiescence: check,
            // 실제로 주입이 끝났을 때만 센다. 가드나 포커스 검사에 걸려 버려진 확장은
            // 일어나지 않은 확장이다 — 통계가 그걸 확장이라고 우기면 안 된다.
            completion: { [weak self] in self?.store.recordExpansion() }
        )
    }
}
