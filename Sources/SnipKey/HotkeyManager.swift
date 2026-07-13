import AppKit
import Carbon.HIToolbox
import Combine
import SnipKeyKit

/// Registers global hotkeys (Carbon) for macros and runs their actions.
final class HotkeyManager {
    private let store: Store
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var macroByHotkeyID: [UInt32: HotkeyMacro] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var cancellable: AnyCancellable?

    init(store: Store) {
        self.store = store
        cancellable = store.$macros
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerAll() }
    }

    func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        for macro in store.macros where macro.enabled && macro.hasHotkey {
            register(macro)
        }
    }

    private func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        macroByHotkeyID.removeAll()
    }

    private func register(_ macro: HotkeyMacro) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4B59) /* SNKY */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            macro.keyCode,
            macro.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[id] = ref
            macroByHotkeyID[id] = macro
        } else {
            NSLog("SnipKey: failed to register hotkey for macro \(macro.name) (status \(status))")
        }

    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, refcon -> OSStatus in
                guard let event, let refcon else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.fire(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            refcon,
            nil
        )
        handlerInstalled = true
    }

    private func fire(id: UInt32) {
        guard let macro = macroByHotkeyID[id] else { return }
        ActionRunner.run(macro, store: store)
    }
}

// MARK: - Action execution

enum ActionRunner {

    static func run(_ macro: HotkeyMacro, store: Store) {
        switch macro.kind {
        case .insertText:
            // Text macros support the same macro syntax as snippets.
            let resolved = MacroParser.resolveNested(macro.argument) {
                store.snippet(forAbbreviation: $0)?.content
            }
            let tokens = MacroParser.parse(resolved)
            let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
            let result = MacroParser.render(tokens: tokens, clipboard: clipboardText)
            TextInjector.expand(
                backspaces: 0,
                text: result.text,
                cursorOffsetFromEnd: result.cursorOffsetFromEnd,
                trailingKeys: result.trailingKeys,
                restoreClipboardAfter: store.settings.clipboardRestoreDelay,
                expectedPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
            )

        case .runShellScript:
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", macro.argument]
                do {
                    try process.run()
                } catch {
                    NSLog("SnipKey: shell macro '\(macro.name)' failed: \(error)")
                }
            }

        case .runAppleScript:
            DispatchQueue.main.async {
                var error: NSDictionary?
                NSAppleScript(source: macro.argument)?.executeAndReturnError(&error)
                if let error {
                    NSLog("SnipKey: AppleScript macro '\(macro.name)' failed: \(error)")
                }
            }

        case .openURL:
            let raw = macro.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
            }

        case .openApp:
            let name = macro.argument.trimmingCharacters(in: .whitespacesAndNewlines)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = name.hasPrefix("/") ? [name] : ["-a", name]
            try? process.run()
        }
    }
}

// MARK: - Hotkey formatting helpers

enum HotkeyFormatter {

    static func description(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        guard keyCode != 0 || carbonModifiers != 0 else { return "None" }
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + keyName(for: keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func keyName(for keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
            kVK_Escape: "⎋", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
            kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = special[Int(keyCode)] { return name }

        // Translate via the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, 4, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "key\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
