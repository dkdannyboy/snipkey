import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import SnipKeyKit

struct SettingsTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var loc: LocalizationManager
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
                    Text(loc.s("settings.loadFailure.header"))
                }
            }

            if store.remoteChange != nil {
                Section {
                    RemoteChangeView(syncMessage: $syncMessage)
                } header: {
                    Text(loc.s("settings.remoteChange.header"))
                }
            }

            Section {
                Toggle(loc.s("settings.general.enableExpansion"), isOn: $store.settings.expansionEnabled)
                Toggle(loc.s("settings.general.playSound"), isOn: $store.settings.playSoundOnExpand)
                Toggle(loc.s("settings.general.launchAtLogin"), isOn: $launchAtLogin)
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
                Text(loc.s("settings.general.header"))
            }

            Section {
                // Picker의 selection을 loc.language에 직접 묶는다. 고르는 순간 @Published가
                // 바뀌어 이 뷰를 포함한 모든 SwiftUI 뷰가 즉시 다시 그려진다(재시작 불필요).
                Picker(loc.s("settings.language.header"), selection: $loc.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(loc.displayName(for: language)).tag(language)
                    }
                }
            } header: {
                Text(loc.s("settings.language.header"))
            }

            Section {
                Toggle(loc.s("settings.search.enable"), isOn: $store.settings.inlineSearchEnabled)
                HStack {
                    Text(loc.s("settings.search.shortcut"))
                    Spacer()
                    ShortcutRecorderView(
                        keyCode: $store.settings.inlineSearchKeyCode,
                        modifiers: $store.settings.inlineSearchModifiers
                    )
                    .disabled(!store.settings.inlineSearchEnabled)
                }
                Text(loc.s("settings.search.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(loc.s("settings.search.header"))
            }

            Section {
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .red)
                    Text(accessibilityGranted
                         ? loc.s("settings.permission.granted")
                         : loc.s("settings.permission.required"))
                    Spacer()
                    if !accessibilityGranted {
                        Button(loc.s("settings.permission.openSettings")) {
                            ExpansionEngine.requestAccessibilityPermission()
                            ExpansionEngine.openAccessibilitySettings()
                        }
                    }
                }
                if !accessibilityGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc.s("settings.permission.stale.title"))
                            .font(.callout).bold()
                        Text(loc.s("settings.permission.stale.body"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(loc.s("settings.permission.clearRegrant")) {
                            ExpansionEngine.resetAccessibilityGrant()
                            ExpansionEngine.openAccessibilitySettings()
                        }
                    }
                }
            } header: {
                Text(loc.s("settings.permission.header"))
            }

            Section {
                HStack {
                    Button(loc.s("settings.data.importTE")) { importFromTextExpander() }
                    Button(loc.s("settings.data.importFolder")) { importFromChosenFolder() }
                    Button(loc.s("settings.data.export")) { exportSnippets() }
                    Button(loc.s("settings.data.openLog")) { NSWorkspace.shared.open(Log.fileURL) }
                }
                Text(loc.s("settings.data.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(loc.s("settings.data.header"))
            }

            Section {
                syncSection
            } header: {
                Text(loc.s("settings.sync.header"))
            }

            Section {
                LabeledContent(loc.s("settings.stats.groups"), value: "\(store.groups.count)")
                LabeledContent(loc.s("settings.stats.snippets"), value: "\(store.allSnippets.count)")
                // Hotkey macros 통계는 뺀다 — 그 기능을 이 버전에서 감췄으므로,
                // 감춘 기능의 개수를 설정에 노출하면 안 된다(store.macros 데이터는 그대로 둔다).
                LabeledContent(loc.s("settings.stats.expansions"), value: "\(store.expansionCount)")
            } header: {
                Text(loc.s("settings.stats.header"))
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
            Text(store.isUsingConfiguredLocation ? loc.s("settings.sync.syncingVia") : loc.s("settings.sync.storingLocally"))
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
            Button(loc.s("settings.sync.saveAs")) { saveSnippetsAs() }
            // 두 번째 Mac: 기존 동기화 파일을 가리킨다. 로컬을 먼저 백업하고 대상을 덮지 않는다.
            Button(loc.s("settings.sync.link")) { linkToSnippets() }
            // 로컬 기본으로 돌아간다. 동기화 파일은 지우지 않는다.
            Button(loc.s("settings.sync.dontSync")) { confirmStopSyncing() }
                .disabled(!store.isUsingConfiguredLocation)
        }

        Text(loc.s("settings.sync.help"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        // 다중 Mac 설정을 헷갈리지 않게 단계로 안내한다: 한쪽은 저장, 다른 쪽은 연결.
        Text(loc.s("settings.sync.steps"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text(loc.s("settings.sync.caveat"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

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
                        Text(loc.s("settings.sync.conflictCopy"))
                            .font(.callout)
                        if let date = conflict.modificationDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(loc.s("settings.sync.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([conflict.url])
                    }
                    Button(loc.s("settings.sync.loadVersion")) {
                        switch store.importConflictVersion(at: conflict.url) {
                        case .saved:
                            syncMessage = loc.s("settings.sync.loadedConflict")
                        default:
                            syncMessage = loc.s("settings.sync.loadConflictFailed")
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
        panel.prompt = loc.s("settings.sync.savePanel.prompt")
        panel.message = loc.s("settings.sync.savePanel.message")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let result = store.saveSnippetsAs(toDirectory: folder)
        if result.success {
            syncMessage = loc.s("settings.sync.savedMessage", store.allSnippets.count, breadcrumb(for: result.activeLocation))
        } else {
            syncMessage = loc.s("settings.sync.saveFailed", result.message ?? "unknown error")
        }
    }

    private func linkToSnippets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.json]
        panel.prompt = loc.s("settings.sync.linkPanel.prompt")
        panel.message = loc.s("settings.sync.linkPanel.message")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let result = store.linkToSnippets(at: file)
        var msg = loc.s("settings.sync.nowSyncing", breadcrumb(for: result.activeLocation))
        if let backup = result.backupURL {
            msg += loc.s("settings.sync.linkBackup", backup.lastPathComponent)
        }
        syncMessage = msg
    }

    private func confirmStopSyncing() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = loc.s("settings.sync.stopTitle")
        alert.informativeText = loc.s("settings.sync.stopMessage")
        alert.addButton(withTitle: loc.s("settings.sync.stopButton"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = store.stopSyncing()
        syncMessage = loc.s("settings.sync.stoppedMessage", breadcrumb(for: result.activeLocation))
    }

    // MARK: - Import / Export

    private func importFromTextExpander() {
        let detected = TEImporter.detectDataFolders()
        guard let folder = detected.first else {
            importMessage = loc.s("settings.import.notFound")
            return
        }
        runImport(folder)
    }

    private func importFromChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = loc.s("settings.import.panelMessage")
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
                var msg = loc.s("settings.import.success", result.snippetCount, result.groups.count, result.sourcePath)
                if result.richTextCount > 0 {
                    msg += loc.s("settings.import.richTextNote", result.richTextCount)
                }
                // TextExpander에서 막 가져왔는데 그게 아직 켜져 있으면 같은 약어를 둘이
                // 각자 확장해 두 번 나온다. 가져오기 직후가 이 안내를 하기 딱 좋은 시점이다.
                if TextExpanderDetection.isRunning() {
                    msg += "\n" + loc.s("warn.textExpanderRunning")
                }
                importMessage = msg
            case .blockedByLoadFailure:
                importMessage = loc.s("settings.import.blockedLoadFailure")
            case .blockedByRemoteChange:
                importMessage = loc.s("settings.import.blockedRemote")
            case .blockedByUnavailableLibrary:
                importMessage = loc.s("settings.import.blockedUnavailable")
            case .blockedByNewerSchema:
                importMessage = loc.s("settings.import.blockedNewerSchema")
            case .failed(let message):
                importMessage = loc.s("settings.import.saveFailed", message)
            }
        } catch {
            importMessage = loc.s("settings.import.failed", error.localizedDescription)
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
    @EnvironmentObject var loc: LocalizationManager
    let failure: Store.LoadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                loc.s("loadFailure.title"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)

            Text(loc.s("loadFailure.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(failure.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let backup = failure.backupURL {
                Text(loc.s("loadFailure.backup", backup.lastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(loc.s("loadFailure.showFile")) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [failure.backupURL ?? failure.originalURL]
                    )
                }
                Button(loc.s("loadFailure.tryAgain")) {
                    if !store.retryLoadingStore() {
                        NSSound.beep()
                    }
                }
                Button(loc.s("loadFailure.startFresh"), role: .destructive) {
                    confirmStartFresh()
                }
            }
        }
    }

    private func confirmStartFresh() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc.s("loadFailure.confirmTitle")
        alert.informativeText = failure.backupURL.map {
            loc.s("loadFailure.confirmWithBackup", $0.path)
        } ?? loc.s("loadFailure.confirmNoBackup")
        alert.addButton(withTitle: loc.s("loadFailure.confirmButton"))
        alert.addButton(withTitle: loc.s("common.cancel"))
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
    @EnvironmentObject var loc: LocalizationManager
    @Binding var syncMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                loc.s("remoteChange.title"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.orange)

            Text(loc.s("remoteChange.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(loc.s("remoteChange.takeTheirs")) {
                    let r = store.resolveByTakingRemote()
                    syncMessage = r.backupURL.map {
                        loc.s("remoteChange.tookTheirsBackup", $0.lastPathComponent)
                    } ?? loc.s("remoteChange.tookTheirs")
                }
                Button(loc.s("remoteChange.keepMine")) {
                    let r = store.resolveByKeepingLocal()
                    syncMessage = r.backupURL.map {
                        loc.s("remoteChange.keptMineBackup", $0.lastPathComponent)
                    } ?? loc.s("remoteChange.keptMine")
                }
                Button(loc.s("remoteChange.keepBoth")) {
                    let r = store.resolveByKeepingBoth()
                    syncMessage = r.backupURL.map {
                        loc.s("remoteChange.keptBothBackup", $0.lastPathComponent)
                    } ?? loc.s("remoteChange.keptBoth")
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
