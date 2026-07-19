import AppKit
import SwiftUI
import SnipKeyKit

/// An NSPanel that always accepts keyboard focus. Without this, typing meant
/// for the fill-in fields leaks back into the app the user was typing in.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Treats closing the panel (red button) as a cancel, so the app always
/// returns to menu-bar-only mode.
private final class PanelCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Floating panel that collects fill-in values before an expansion completes.
enum FillInPanel {

    /// Keeps the close watcher alive for as long as the panel is on screen.
    private static var closeWatcher: PanelCloseWatcher?

    /// Presents the panel and returns it. Calls `completion` with field values
    /// keyed by FillField.id, or nil if the user cancelled.
    @discardableResult
    static func present(
        title: String,
        fields: [FillField],
        loc: LocalizationManager,
        completion: @escaping ([Int: String]?) -> Void
    ) -> NSPanel {
        // .nonactivatingPanel lets the panel take keyboard focus even though
        // SnipKey is a menu-bar-only app that macOS will not fully activate.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // title은 스니펫 제목(사용자 데이터)이라 번역하지 않고, 비었을 때의 폴백만 현지화한다.
        panel.title = title.isEmpty ? loc.s("fillin.title") : title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        var finished = false
        let finish: ([Int: String]?) -> Void = { values in
            guard !finished else { return }
            finished = true
            panel.close()
            completion(values)
        }

        let watcher = PanelCloseWatcher { finish(nil) }
        closeWatcher = watcher
        panel.delegate = watcher

        let view = FillInFormView(fields: fields, loc: loc, onSubmit: { finish($0) }, onCancel: { finish(nil) })
        panel.contentView = NSHostingView(rootView: view)
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Activation is asynchronous; re-assert key status once the app has
        // actually come forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            Log.write("panel key=\(panel.isKeyWindow) appActive=\(NSApp.isActive)")
        }
        return panel
    }
}

private struct FillInFormView: View {
    let fields: [FillField]
    /// 패널은 NSHostingView로 띄우므로 SwiftUI 환경 밖이다. EnvironmentObject 대신
    /// 값으로 넘겨받는다. 표시 시점에 문자열을 읽으니 즉시-전환에도 문제없다.
    let loc: LocalizationManager
    let onSubmit: ([Int: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [Int: String] = [:]
    @FocusState private var focusedField: Int?

    /// First field the user can type into — popups and toggles don't need focus.
    private var firstTypableField: Int? {
        fields.first { field in
            switch field.kind {
            case .text, .area: return true
            default: return false
            }
        }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields) { field in
                        fieldView(field)
                    }
                }
                .padding(2)
            }
            HStack {
                Spacer()
                Button(loc.s("common.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(loc.s("fillin.insert")) { onSubmit(values) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 420, maxHeight: 480)
        .onAppear {
            for field in fields {
                values[field.id] = field.defaultValue
            }
            // Focus the first typable field so the user can start typing at once.
            // A short delay lets the panel finish becoming key first.
            if let first = firstTypableField {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedField = first
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: FillField) -> some View {
        switch field.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                TextField(field.name, text: binding(field.id))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: field.id)
                    .onSubmit { onSubmit(values) }
            }
        case .area:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding(field.id))
                    .font(.body)
                    .frame(height: 80)
                    .focused($focusedField, equals: field.id)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        case .popup(let options):
            VStack(alignment: .leading, spacing: 4) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                Picker(field.name, selection: binding(field.id)) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .part:
            Toggle(loc.s("fillin.include", field.name), isOn: partBinding(field.id))
        }
    }

    private func binding(_ id: Int) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = $0 }
        )
    }

    private func partBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { (values[id] ?? "yes").lowercased() != "no" },
            set: { values[id] = $0 ? "yes" : "no" }
        )
    }
}
