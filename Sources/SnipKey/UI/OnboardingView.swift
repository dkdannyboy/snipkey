import SwiftUI
import AppKit
import SnipKeyKit

/// First-launch assistant: welcome → permission → data → try it out.
struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var loc: LocalizationManager
    let onFinished: () -> Void

    @State private var step = 0
    @State private var accessibilityGranted = ExpansionEngine.hasAccessibilityPermission
    @State private var importSummary: String?
    @State private var detectedFolder: URL?
    @State private var tryItText = ""

    private let permissionTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            Divider()
            HStack {
                if step > 0 {
                    Button(loc.s("common.back")) { step -= 1 }
                }
                Spacer()
                stepDots
                Spacer()
                if step < totalSteps - 1 {
                    Button(loc.s("onboarding.continue")) { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(loc.s("onboarding.start")) { onFinished() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .onAppear {
            detectedFolder = TEImporter.detectDataFolders().first
        }
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = ExpansionEngine.hasAccessibilityPermission
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: permission
        case 2: dataSetup
        default: tryIt
        }
    }

    // MARK: Step 1 — Welcome

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.square.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(loc.s("onboarding.welcome.title"))
                .font(.largeTitle.bold())
            Text(loc.s("onboarding.welcome.subtitle"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                featureRow("keyboard", loc.s("onboarding.feature.expansion.title"),
                           loc.s("onboarding.feature.expansion.detail"))
                featureRow("square.and.arrow.down", loc.s("onboarding.feature.migration.title"),
                           loc.s("onboarding.feature.migration.detail"))
                // Hotkey macros 소개는 뺀다 — 이 버전에서 그 기능을 감췄으므로, 온보딩이
                // 도달할 수 없는 기능을 광고하면 안 된다.
                featureRow("questionmark.text.page", loc.s("onboarding.feature.fillin.title"),
                           loc.s("onboarding.feature.fillin.detail"))
            }
            .padding(.top, 8)
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 2 — Permission

    private var permission: some View {
        VStack(spacing: 16) {
            Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "hand.raised.square")
                .font(.system(size: 48))
                .foregroundStyle(accessibilityGranted ? .green : Color.accentColor)
            Text(loc.s("onboarding.permission.title"))
                .font(.title.bold())
            Text(loc.s("onboarding.permission.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if accessibilityGranted {
                Label(loc.s("onboarding.permission.granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 10) {
                    Button(loc.s("onboarding.permission.grant")) {
                        ExpansionEngine.requestAccessibilityPermission()
                        ExpansionEngine.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Text(loc.s("onboarding.permission.instructions"))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                    Button(loc.s("onboarding.permission.clearRetry")) {
                        ExpansionEngine.resetAccessibilityGrant()
                        ExpansionEngine.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: Step 3 — Data

    private var dataSetup: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(loc.s("onboarding.data.title"))
                .font(.title.bold())

            if let importSummary {
                Label(importSummary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text(loc.s("onboarding.data.subtitle"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                if let folder = detectedFolder {
                    Button {
                        runImport(folder)
                    } label: {
                        VStack(spacing: 2) {
                            Text(loc.s("onboarding.data.importTE")).bold()
                            Text(loc.s("onboarding.data.found", folder.path))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 380)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(loc.s("onboarding.data.chooseFolder")) { chooseFolder() }
                Button(loc.s("onboarding.data.startFresh")) { startFresh() }
            }
            .padding(.top, 4)
        }
    }

    private func runImport(_ folder: URL) {
        do {
            let result = try TEImporter.importFolder(folder)
            switch store.importGroups(result.groups) {
            case .saved:
                importSummary = loc.s("onboarding.import.success", result.snippetCount, result.groups.count)
            case .blockedByLoadFailure:
                importSummary = loc.s("onboarding.import.blockedLoadFailure")
            case .blockedByRemoteChange, .blockedByUnavailableLibrary, .blockedByNewerSchema:
                importSummary = loc.s("onboarding.import.blockedOther")
            case .failed(let message):
                importSummary = loc.s("settings.import.saveFailed", message)
            }
        } catch {
            importSummary = loc.s("settings.import.failed", error.localizedDescription)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = loc.s("onboarding.data.panelMessage")
        if panel.runModal() == .OK, let url = panel.url {
            runImport(url)
        }
    }

    private func startFresh() {
        guard !store.isReadOnlyUntilRecovered else {
            importSummary = loc.s("onboarding.startFresh.readOnly")
            return
        }
        // "Getting Started"는 데이터 씨앗의 이름(파일에 그대로 남는 사용자 데이터)이라
        // 번역하지 않는다 — 여기 존재 여부 검사가 그 영어 이름에 걸려 있기 때문이다.
        if !store.groups.contains(where: { $0.name == "Getting Started" }) {
            store.groups.append(Store.starterGroup())
        }
        switch store.saveNow() {
        case .saved:
            importSummary = loc.s("onboarding.startFresh.added")
        case .blockedByLoadFailure:
            importSummary = loc.s("onboarding.startFresh.blockedLoadFailure")
        case .blockedByRemoteChange, .blockedByUnavailableLibrary, .blockedByNewerSchema:
            importSummary = loc.s("onboarding.startFresh.blockedOther")
        case .failed(let message):
            importSummary = loc.s("onboarding.startFresh.saveFailed", message)
        }
    }

    // MARK: Step 4 — Try it

    private var tryIt: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(loc.s("onboarding.tryit.title"))
                .font(.title.bold())

            if accessibilityGranted {
                Text(loc.s("onboarding.tryit.body"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Label(loc.s("onboarding.tryit.needPermission"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            TextField(placeholderAbbrev, text: $tryItText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(width: 360)

            VStack(alignment: .leading, spacing: 6) {
                Text(loc.s("onboarding.tryit.tips.title")).font(.headline)
                Text(loc.s("onboarding.tryit.tip1"))
                Text(loc.s("onboarding.tryit.tip2"))
                // Hotkeys 탭 안내는 뺀다 — 탭 자체를 감췄으므로 없는 탭을 가리키면 안 된다.
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .onAppear {
            // The engine needs to be running for the demo box to expand.
            (NSApp.delegate as? AppDelegate)?.startEngineIfPossible()
        }
    }

    private var placeholderAbbrev: String {
        if let first = store.allSnippets.first(where: { $0.enabled && !$0.abbreviation.isEmpty }) {
            return loc.s("onboarding.tryit.placeholder", first.abbreviation)
        }
        return loc.s("onboarding.tryit.placeholder", ";hello")
    }
}
