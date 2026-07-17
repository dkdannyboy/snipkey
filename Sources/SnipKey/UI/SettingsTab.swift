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
    @State private var syncMessage: String?

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

            if store.remoteChange != nil {
                Section {
                    RemoteChangeView(syncMessage: $syncMessage)
                } header: {
                    Text("Another Mac Changed Your Snippets")
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
                Toggle("Enable search-anywhere palette", isOn: $store.settings.inlineSearchEnabled)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorderView(
                        keyCode: $store.settings.inlineSearchKeyCode,
                        modifiers: $store.settings.inlineSearchModifiers
                    )
                    .disabled(!store.settings.inlineSearchEnabled)
                }
                Text("Press it while typing in any app to search your snippets by abbreviation, label, or content, then press Return to expand the one you want. Handy when you cannot remember an abbreviation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Search Anywhere")
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
                syncSection
            } header: {
                Text("Sync")
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

    // MARK: - Sync (M4)
    //
    // TextExpander의 Sync 탭을 본떴다. 앱은 동기화를 **구현하지 않는다** — 사용자가
    // iCloud Drive처럼 이미 동기화 중인 폴더를 가리키면 클라우드가 동기화한다. 여기서
    // 하는 일은 두 가지뿐이다: 위치를 고르게 하고, 어떤 전환도 데이터를 파괴하지 않게 한다.

    @ViewBuilder
    private var syncSection: some View {
        // 현재 활성 위치를 breadcrumb으로 보여준다 (REQ-LOC-007).
        HStack(alignment: .firstTextBaseline) {
            Text(store.isUsingConfiguredLocation ? "Syncing via" : "Storing locally")
                .foregroundStyle(.secondary)
            Spacer()
            Text(breadcrumb(for: store.activeLocationURL))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }

        HStack {
            // 첫 Mac: 동기화 폴더로 라이브러리를 복사한다. 현재 331개를 절대 버리지 않는다.
            Button("Save Snippets As…") { saveSnippetsAs() }
            // 두 번째 Mac: 기존 동기화 파일을 가리킨다. 로컬을 먼저 백업하고 대상을 덮지 않는다.
            Button("Link to Snippets…") { linkToSnippets() }
            // 로컬 기본으로 돌아간다. 동기화 파일은 지우지 않는다.
            Button("Don't Sync") { confirmStopSyncing() }
                .disabled(!store.isUsingConfiguredLocation)
        }

        Text("Point SnipKey at a folder your cloud service already syncs (for example iCloud Drive). SnipKey does not sync by itself — it only chooses the location and refuses to destroy your snippets when a file changes underneath it.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let syncMessage {
            Text(syncMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        // iCloud가 만든 미해결 충돌 복사본. 앱은 승자를 고르지 않고 보여주기만 한다.
        let conflicts = store.unresolvedConflicts()
        if !conflicts.isEmpty {
            ForEach(conflicts) { conflict in
                HStack {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Conflict copy")
                            .font(.callout)
                        if let date = conflict.modificationDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([conflict.url])
                    }
                    Button("Load This Version") {
                        switch store.importConflictVersion(at: conflict.url) {
                        case .saved:
                            syncMessage = "Loaded the conflict copy into your library."
                        default:
                            syncMessage = "Could not load that conflict copy."
                        }
                    }
                }
            }
        }
    }

    /// 홈 디렉터리는 물결표로 줄여 읽기 쉬운 경로로 만든다.
    private func breadcrumb(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func saveSnippetsAs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        panel.message = "Choose a folder your cloud service syncs (e.g. a folder in iCloud Drive)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let result = store.saveSnippetsAs(toDirectory: folder)
        if result.success {
            syncMessage = "Saved \(store.allSnippets.count) snippets to \(breadcrumb(for: result.activeLocation)). SnipKey now syncs from there; your previous local copy is left untouched."
        } else {
            syncMessage = "Could not save there: \(result.message ?? "unknown error")."
        }
    }

    private func linkToSnippets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.json]
        panel.prompt = "Link"
        panel.message = "Choose the existing SnipKey snippet file in your synced folder."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let result = store.linkToSnippets(at: file)
        var msg = "Now syncing from \(breadcrumb(for: result.activeLocation))."
        if let backup = result.backupURL {
            msg += " Your previous local snippets were backed up to \(backup.lastPathComponent) and can be recovered."
        }
        syncMessage = msg
    }

    private func confirmStopSyncing() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Stop syncing this Mac?"
        alert.informativeText = "SnipKey will copy your current snippets back to this Mac and stop following the synced file. The synced file itself is left in place for your other Macs."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = store.stopSyncing()
        syncMessage = "Stopped syncing. Your snippets are stored locally again at \(breadcrumb(for: result.activeLocation)); the synced file was left in place."
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
            switch store.importGroups(result.groups) {
            case .saved:
                var msg = "Imported \(result.snippetCount) snippets in \(result.groups.count) groups from \(result.sourcePath)."
                if result.richTextCount > 0 {
                    msg += " \(result.richTextCount) formatted snippets were converted to plain text."
                }
                importMessage = msg
            case .blockedByLoadFailure:
                importMessage = "Nothing was imported. SnipKey cannot read your existing snippet library and will not overwrite it — resolve that above first."
            case .blockedByRemoteChange:
                importMessage = "Nothing was imported. Your snippet library was changed by another Mac since SnipKey read it, and importing would overwrite that change. Quit and reopen SnipKey to pick up the newer library first."
            case .blockedByUnavailableLibrary:
                importMessage = "Nothing was imported. SnipKey cannot find your snippet library at its configured location — it may still be downloading, or its volume may be unmounted."
            case .blockedByNewerSchema:
                importMessage = "Nothing was imported. Your snippet library was written by a newer version of SnipKey, and this version would silently drop what it does not understand. Update SnipKey first."
            case .failed(let message):
                importMessage = "Nothing was imported. Saving failed: \(message)"
            }
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

/// 다른 Mac이 파일을 바꿔 저장이 막혔을 때 보여준다. `LoadFailureView`와 같은
/// 철학이다 — 의심스러우면 앱이 승자를 고르지 않고 사용자에게 묻는다. 세 옵션 모두
/// 양쪽 버전을 디스크에 남긴다 (REQ-WRITE-005).
private struct RemoteChangeView: View {
    @EnvironmentObject var store: Store
    @Binding var syncMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Your snippet library was changed on another Mac after SnipKey read it, so saving is paused.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.orange)

            Text("Nothing has been lost. Choose what to do — every option keeps both versions recoverable on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Take Theirs") {
                    let r = store.resolveByTakingRemote()
                    syncMessage = r.backupURL.map {
                        "Loaded the other Mac's version. Your local edits were backed up to \($0.lastPathComponent)."
                    } ?? "Loaded the other Mac's version."
                }
                Button("Keep Mine") {
                    let r = store.resolveByKeepingLocal()
                    syncMessage = r.backupURL.map {
                        "Kept your version. The other Mac's version was backed up to \($0.lastPathComponent)."
                    } ?? "Kept your version."
                }
                Button("Keep Both") {
                    let r = store.resolveByKeepingBoth()
                    syncMessage = r.backupURL.map {
                        "Wrote your version to \($0.lastPathComponent) and loaded the other Mac's version."
                    } ?? "Kept both versions."
                }
            }
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
