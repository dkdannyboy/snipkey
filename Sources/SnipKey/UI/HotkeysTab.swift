import SwiftUI
import AppKit
import SnipKeyKit

struct HotkeysTab: View {
    @EnvironmentObject var store: Store
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            macroList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            editorPane
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }

    private var macroList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.macros) { macro in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(macro.name.isEmpty ? "Untitled" : macro.name)
                            Text(macro.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(HotkeyFormatter.description(keyCode: macro.keyCode, carbonModifiers: macro.modifiers))
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        if !macro.enabled {
                            Image(systemName: "pause.circle").foregroundStyle(.orange)
                        }
                    }
                    .tag(macro.id)
                }
            }
            HStack {
                Button {
                    let m = HotkeyMacro(name: "New Macro")
                    store.macros.append(m)
                    selectedID = m.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    if let id = selectedID {
                        store.macros.removeAll { $0.id == id }
                        selectedID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let id = selectedID, let macro = store.macros.first(where: { $0.id == id }) {
            MacroEditor(macro: macro) { updated in
                if let idx = store.macros.firstIndex(where: { $0.id == updated.id }) {
                    store.macros[idx] = updated
                }
            }
            .id(id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "command.square")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Hotkey macros run an action with a global shortcut —\ninsert text, run a script, open an app or URL.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("A lightweight replacement for the Keyboard Maestro basics.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MacroEditor: View {
    @State var macro: HotkeyMacro
    let onChange: (HotkeyMacro) -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Macro name", text: $macro.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hotkey").font(.caption).foregroundStyle(.secondary)
                    ShortcutRecorderView(keyCode: $macro.keyCode, modifiers: $macro.modifiers)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $macro.kind) {
                        ForEach(MacroActionKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Toggle("Enabled", isOn: $macro.enabled)
                    .padding(.top, 14)
                Spacer()
            }

            Text(argumentTitle).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $macro.argument)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Button("Test Run") {
                    ActionRunner.run(macro, store: store)
                }
                Text(testHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(14)
        .onChange(of: macro) { newValue in
            onChange(newValue)
        }
    }

    private var argumentTitle: String {
        switch macro.kind {
        case .insertText: return "Text to insert (snippet macros like %date:…% work here too)"
        case .runShellScript: return "Shell script (runs with /bin/zsh -lc)"
        case .runAppleScript: return "AppleScript source"
        case .openURL: return "URL or file path"
        case .openApp: return "Application name (e.g. Safari) or full path"
        }
    }

    private var testHint: String {
        macro.kind == .insertText
            ? "Insert Text pastes at the current cursor — switch to another app to try it via the hotkey."
            : ""
    }
}

/// Click, then press the desired key combination.
struct ShortcutRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording
                 ? "Press keys…"
                 : HotkeyFormatter.description(keyCode: keyCode, carbonModifiers: modifiers))
                .frame(width: 140)
        }
        .background(recording ? Color.accentColor.opacity(0.2) : Color.clear)
        .contextMenu {
            Button("Clear") {
                keyCode = 0
                modifiers = 0
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // escape cancels
                stopRecording()
                return nil
            }
            let mods = HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return nil } // require at least one modifier
            keyCode = UInt32(event.keyCode)
            modifiers = mods
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
