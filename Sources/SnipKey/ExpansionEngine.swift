import AppKit
import Carbon.HIToolbox
import SnipKeyKit

/// Watches global keystrokes with a CGEvent tap, matches typed abbreviations
/// against the store, and triggers expansion.
final class ExpansionEngine {
    private let store: Store
    /// 채우기 패널의 정적 문자열(제목 폴백·버튼·"포함:")을 현지화하기 위해 참조를 들고 있는다.
    private let loc: LocalizationManager
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private let maxBuffer = 64

    /// 마지막 '진짜' 사용자 입력(키 또는 마우스 클릭)의 이벤트 시각. 첫 백스페이스를
    /// 내보내기 직전에 이걸 보고, 가드를 무장한 뒤로 입력이 들어왔다면 확장을 통째로 버린다.
    ///
    /// 합성 이벤트(우리가 쏜 백스페이스·⌘V)는 절대 여기 찍히지 않는다. 찍히면 인젝터의
    /// 첫 백스페이스가 바로 그 확장을 스스로 취소해 버린다.
    private let inputClock = InputClock()
    /// The open fill-in panel, if any. Typing is ignored while it is on screen.
    /// Deriving suspension from the window itself means a panel that closes
    /// unexpectedly can never leave the engine permanently deaf.
    private weak var activePanel: NSWindow?
    private var isSuspended: Bool {
        guard let panel = activePanel else { return false }
        return panel.isVisible
    }

    var isRunning: Bool { eventTap != nil }

    init(store: Store, loc: LocalizationManager) {
        self.store = store
        self.loc = loc
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
            // 클릭은 커서를 옮긴다 — 키를 하나도 남기지 않으면서. 매치 이후에 대상 앱
            // 어딘가를 클릭하면, 뒤이어 나가는 백스페이스가 약어가 아니라 그 클릭한
            // 자리를 지운다. 같은 앱이라 PID 검사도, '무장 이후 키 입력' 검사도 통과하므로
            // 클릭까지 입력 시계에 찍어야 그 확장이 취소된다.
            //
            // 키와 똑같이 '이벤트 시각'을 쓴다(관측 시각이 아니라). 필인 패널을 닫는
            // 순간 이 무장이 걸리는데, 패널 '안'을 클릭했던 이벤트는 그 무장보다 이르므로
            // 판정에 걸리지 않는다 — 정상 필인은 살아남는다. 우리는 합성 마우스 이벤트를
            // 아예 쏘지 않으므로 여기 오는 클릭은 전부 진짜 사용자 입력이다.
            inputClock.mark(at: InputClock.seconds(sinceBootNanos: event.timestamp))
            buffer = ""
            return
        }

        guard type == .keyDown else { return }

        // 여기가 '진짜 사용자 키'의 유일한 관문이다. 합성 이벤트는 위에서 걸러졌다.
        //
        // 조건 없이 전부 찍는다 — 버퍼를 비우는 키(Escape·화살표)도, 수정자 조합(⌘V)도,
        // 확장이 꺼져 있을 때의 키도, 필인 패널에 치는 키도. 그 어느 것도 대상 앱의
        // 텍스트나 커서를 움직일 수 있고, 움직였다면 백스페이스가 지울 자리는 우리가
        // 계산한 그 자리가 아니다.
        //
        // 패널에 치는 키까지 찍어도 정상 필인이 취소되지 않는 이유: 그 키들의 '이벤트
        // 시각'은 패널이 닫히는 시점보다 이르고, 주입용 가드는 패널이 닫히는 순간에
        // 무장하기 때문이다. 무장 이전의 키는 판정에 걸리지 않는다. `!isSuspended` 같은
        // 예외 처리가 필요 없다.
        //
        // 반드시 '이벤트 시각'을 넘긴다 — 우리가 이 콜백에서 관측한 시각이 아니라.
        // 관측 시각을 쓰면 필인 패널을 닫는 Return이 무장보다 늦게 기록될 수 있고,
        // 그러면 멀쩡한 필인 확장이 스스로 취소된다.
        inputClock.mark(at: InputClock.seconds(sinceBootNanos: event.timestamp))

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
            // 지금 무장한다. 방금 친 종결자의 이벤트 시각은 이 시점보다 이르므로 판정에
            // 걸리지 않고, 이 뒤로 도착하는 입력(키·클릭)은 전부 확장을 취소시킨다.
            let quiescence = inputClock.arm()
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

        // 필인은 패널을 띄우고 사용자를 기다린다. 지우기는 패널이 닫힌 '뒤'에야 나가므로,
        // 확장 하나가 서로 다른 두 구간을 지나간다. 구간마다 가드를 새로 무장한다.
        //
        //   구간 1 (매치 → 패널 표시): 키가 대상 앱으로 들어간다. 여기서 타이핑을
        //     이어갔다면 나중에 나갈 백스페이스는 이미 어긋난다. 패널을 띄우기 '전'에
        //     정착 시간만큼 기다렸다가 매치 시점 가드로 판정하고, 키가 들어왔으면
        //     패널조차 띄우지 않는다. (띄워봐야 값만 받아놓고 버릴 확장이다.)
        //
        //     이 검사는 없앨 수 없다. 패널에 값을 치면 마지막 키 시각이 앞으로 밀려서,
        //     '패널이 뜨기 전에 대상 앱에 타이핑했다'는 사실이 주입 시점에는 더 이상
        //     보이지 않기 때문이다. 그 정보가 살아 있는 유일한 순간이 여기다.
        //
        //   구간 2 (패널 닫힘 → 주입): 패널이 닫히는 순간 가드를 새로 무장한다
        //     (showFillInPanel 참고). 패널에 친 값들은 이벤트 시각이 그보다 이르므로
        //     걸리지 않고, 포커스가 돌아온 뒤에 대상 앱에 친 키는 전부 걸린다.
        let show = { [weak self] in
            self?.showFillInPanel(
                snippet: snippet,
                tokens: tokens,
                backspaces: backspaces,
                terminator: terminator,
                targetApp: targetApp,
                quiescence: quiescence
            )
        }

        guard let quiescence, backspaces > 0 else {
            show()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + TextInjector.quiescenceSettle) { [weak self] in
            guard let self else { return }
            if case .abort = self.inputClock.decide(quiescence) {
                Log.write("expansion cancelled — user input after the match — fill-in panel not shown")
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
        targetApp: NSRunningApplication?,
        quiescence: InputQuiescenceGuard?
    ) {
        let panel = FillInPanel.present(
            title: snippet.displayTitle,
            fields: MacroParser.fillFields(in: tokens),
            loc: loc
        ) { [weak self] values in
            guard let self else { return }
            self.activePanel = nil

            // 포커스를 돌려주기 '전'에, 패널이 닫히는 바로 이 순간 무장한다.
            //
            // 여기부터 주입까지(0.25초 + 인젝터 정착 시간) 대상 앱에 들어간 키는 전부
            // 확장을 취소시킨다. 사용자가 그 창에서 단어를 치고 '멈춰도' 잡힌다 —
            // 정숙 여부가 아니라 '무장 이후에 왔는가'로 묻기 때문이다. 정숙으로 물었을
            // 때는 바로 이 경우를 놓쳐서 사용자가 친 단어가 백스페이스에 먹혔다.
            //
            // 패널을 닫은 그 Return이 여기 걸리지 않는 이유: 우리는 키의 '이벤트 시각'을
            // 기록하는데, 그 Return은 이 무장보다 먼저 눌렸다. 탭 콜백이 늦게 돌아 나중에
            // 기록되더라도 기록되는 값은 눌린 시각이므로 무장 이전이다. 관측 시각을
            // 기준으로 삼았다면 바로 그 Return이 멀쩡한 확장을 취소시켰을 것이다.
            let quiescenceAfterPanel = (quiescence == nil) ? nil : self.inputClock.arm()

            // Return focus to the app the user was typing in.
            targetApp?.activate()
            guard let values else {
                // Cancelled — leave the typed abbreviation in place.
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.inject(
                    tokens: tokens,
                    fillValues: values,
                    backspaces: backspaces,
                    terminator: terminator,
                    targetPID: targetApp?.processIdentifier,
                    quiescence: quiescenceAfterPanel
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
            let clock = inputClock
            check = { clock.decide(quiescence) }
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
