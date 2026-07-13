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

        guard type == .keyDown, !isSuspended, store.settings.expansionEnabled else {
            if isSuspended || !store.settings.expansionEnabled { buffer = "" }
            return
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer = ""
            return
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) else { return }

        buffer += typed
        if buffer.count > maxBuffer {
            buffer = String(buffer.suffix(maxBuffer))
        }

        if let snippet = store.matcher.match(buffer: buffer) {
            Log.write("matched '\(snippet.abbreviation)'")
            buffer = ""
            DispatchQueue.main.async { [weak self] in
                self?.expand(snippet)
            }
        }
    }

    // MARK: - Expansion

    private func expand(_ snippet: Snippet) {
        let resolved = MacroParser.resolveNested(snippet.content) { [weak self] abbrev in
            self?.store.snippet(forAbbreviation: abbrev)?.content
        }
        let tokens = MacroParser.parse(resolved)
        let backspaces = snippet.abbreviation.count

        // The app the abbreviation was typed into. Everything we inject has to
        // land there, not wherever focus drifts to while we work.
        let targetApp = NSWorkspace.shared.frontmostApplication

        if MacroParser.hasFillIns(tokens) {
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
                    self.inject(
                        tokens: tokens,
                        fillValues: values,
                        backspaces: backspaces,
                        targetPID: targetApp?.processIdentifier
                    )
                }
            }
            activePanel = panel
            Log.write("fill panel presented (visible=\(panel.isVisible))")
        } else {
            inject(
                tokens: tokens,
                fillValues: [:],
                backspaces: backspaces,
                targetPID: targetApp?.processIdentifier
            )
        }
    }

    private func inject(
        tokens: [MacroToken],
        fillValues: [Int: String],
        backspaces: Int,
        targetPID: pid_t?
    ) {
        Log.write("inject start (backspaces=\(backspaces))")
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let result = MacroParser.render(
            tokens: tokens,
            fillValues: fillValues,
            clipboard: clipboardText
        )
        TextInjector.expand(
            backspaces: backspaces,
            text: result.text,
            cursorOffsetFromEnd: result.cursorOffsetFromEnd,
            trailingKeys: result.trailingKeys,
            restoreClipboardAfter: store.settings.clipboardRestoreDelay,
            playSound: store.settings.playSoundOnExpand,
            expectedPID: targetPID
        )
        store.recordExpansion()
    }
}
