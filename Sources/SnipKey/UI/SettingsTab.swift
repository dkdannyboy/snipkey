import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import SnipKeyKit

struct SettingsTab: View {
    @EnvironmentObject var store: Store
    @State private var accessibilityGranted = ExpansionEngine.hasAccessibilityPermission
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var importMessage: String?

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let failure = store.loadFailure {
                Section {
                    LoadFailureView(failure: failure)
                } header: {
                    Text("Snippet Library Could Not Be Opened")
                }
            }

            Section {
                Toggle("Enable text expansion", isOn: $store.settings.expansionEnabled)
                Toggle("Play sound when a snippet expands", isOn: $store.settings.playSoundOnExpand)
                Toggle("Launch SnipKey at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("SnipKey: launch-at-login change failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("General")
            }

            Section {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .red)
                    Text(accessibilityGranted
                         ? "Accessibility permission granted"
                         : "Accessibility permission required for expansion")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Open System Settings") {
                            ExpansionEngine.requestAccessibilityPermission()
                            ExpansionEngine.openAccessibilitySettings()
                        }
                    }
                }
                if !accessibilityGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stopped working after updating SnipKey?")
                            .font(.callout).bold()
                        Text("An update changes the app's signature, and macOS keeps showing the old switch as on while ignoring it. Clear the stale entry, then switch SnipKey back on in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Clear Permission and Re-grant…") {
                            ExpansionEngine.resetAccessibilityGrant()
                            ExpansionEngine.openAccessibilitySettings()
                        }
                    }
                }
            } header: {
                Text("Permissions")
            }

            Section {
                HStack {
                    Button("Import from TextExpander…") { importFromTextExpander() }
                    Button("Import from folder…") { importFromChosenFolder() }
                    Button("Export snippets…") { exportSnippets() }
                    Button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
                }
                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data")
            }

            Section {
                LabeledContent("Groups", value: "\(store.groups.count)")
                LabeledContent("Snippets", value: "\(store.allSnippets.count)")
                LabeledContent("Hotkey macros", value: "\(store.macros.count)")
                LabeledContent("Total expansions", value: "\(store.expansionCount)")
            } header: {
                Text("Statistics")
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = ExpansionEngine.hasAccessibilityPermission
        }
    }

    // MARK: - Import / Export

    private func importFromTextExpander() {
        let detected = TEImporter.detectDataFolders()
        guard let folder = detected.first else {
            importMessage = "No TextExpander data found in the usual locations. Use “Import from folder…” to pick a .textexpandersettings or .textexpanderbackup folder."
            return
        }
        runImport(folder)
    }

    private func importFromChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a TextExpander data folder (.textexpandersettings or .textexpanderbackup)"
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            runImport(url)
        }
    }

    private func runImport(_ folder: URL) {
        do {
            let result = try TEImporter.importFolder(folder)
            store.mergeImported(groups: result.groups)
            var msg = "Imported \(result.snippetCount) snippets in \(result.groups.count) groups from \(result.sourcePath)."
            if result.richTextCount > 0 {
                msg += " \(result.richTextCount) formatted snippets were converted to plain text."
            }
            importMessage = msg
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "snipkey-snippets.json"
        if panel.runModal() == .OK, let url = panel.url {
            let data = StoreData(
                groups: store.groups,
                macros: store.macros,
                settings: store.settings,
                expansionCount: store.expansionCount
            )
            if let raw = try? JSONEncoder.snipKeyPublic.encode(data) {
                try? raw.write(to: url)
            }
        }
    }
}

/// Shown when store.json exists but could not be read. Saving is blocked until
/// the user decides what to do, so nothing is overwritten behind their back.
private struct LoadFailureView: View {
    @EnvironmentObject var store: Store
    let failure: Store.LoadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "SnipKey found your snippet file but could not read it, so it is showing an empty library.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)

            Text("Nothing has been overwritten — SnipKey will not save until you choose what to do.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(failure.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let backup = failure.backupURL {
                Text("A copy was kept at \(backup.lastPathComponent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Show the File") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [failure.backupURL ?? failure.originalURL]
                    )
                }
                Button("Try Again") {
                    if !store.retryLoadingStore() {
                        NSSound.beep()
                    }
                }
                Button("Start Fresh (Discard)", role: .destructive) {
                    confirmStartFresh()
                }
            }
        }
    }

    private func confirmStartFresh() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start with an empty snippet library?"
        alert.informativeText = failure.backupURL.map {
            "The unreadable file will be replaced. A copy stays at \($0.path)."
        } ?? "The unreadable file will be replaced, and no backup copy could be made."
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.startFreshDiscardingUnreadableStore()
        }
    }
}

extension JSONEncoder {
    /// Mirror of the internal store encoder for export.
    static var snipKeyPublic: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
