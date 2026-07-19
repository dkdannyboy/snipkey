import SwiftUI
import AppKit
import SnipKeyKit

/// First-launch assistant: welcome → permission → data → try it out.
struct OnboardingView: View {
    @EnvironmentObject var store: Store
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
                    Button("Back") { step -= 1 }
                }
                Spacer()
                stepDots
                Spacer()
                if step < totalSteps - 1 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using SnipKey") { onFinished() }
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
            Text("Welcome to SnipKey")
                .font(.largeTitle.bold())
            Text("Type a short abbreviation anywhere — SnipKey instantly replaces it with your full text.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                featureRow("keyboard", "Text expansion in every app",
                           "Abbreviations like ;sig become full snippets as you type.")
                featureRow("square.and.arrow.down", "TextExpander migration",
                           "Import your existing groups and abbreviations in one click.")
                // Hotkey macros 소개는 뺀다 — 이 버전에서 그 기능을 감췄으므로, 온보딩이
                // 도달할 수 없는 기능을 광고하면 안 된다.
                featureRow("questionmark.text.page", "Fill-in forms",
                           "Snippets can pause and ask for names, amounts, or choices.")
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
            Text("Accessibility Permission")
                .font(.title.bold())
            Text("SnipKey needs macOS Accessibility access to see what you type and to insert your snippets. Nothing you type ever leaves your Mac — SnipKey has no network features at all.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if accessibilityGranted {
                Label("Permission granted — you're all set!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 10) {
                    Button("Grant Access in System Settings") {
                        ExpansionEngine.requestAccessibilityPermission()
                        ExpansionEngine.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("System Settings → Privacy & Security → Accessibility → turn on SnipKey.\nThis page updates automatically once access is granted.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                    Button("Already on but not working? Clear it and try again") {
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
            Text("Your Snippets")
                .font(.title.bold())

            if let importSummary {
                Label(importSummary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text("Coming from TextExpander? Bring everything with you.\nStarting fresh? We'll add a few sample snippets to play with.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                if let folder = detectedFolder {
                    Button {
                        runImport(folder)
                    } label: {
                        VStack(spacing: 2) {
                            Text("Import from TextExpander").bold()
                            Text("Found: \(folder.path)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 380)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Choose a TextExpander folder…") { chooseFolder() }
                Button("Start fresh with sample snippets") { startFresh() }
            }
            .padding(.top, 4)
        }
    }

    private func runImport(_ folder: URL) {
        do {
            let result = try TEImporter.importFolder(folder)
            switch store.importGroups(result.groups) {
            case .saved:
                importSummary = "Imported \(result.snippetCount) snippets in \(result.groups.count) groups. Welcome back!"
            case .blockedByLoadFailure:
                importSummary = "Nothing was imported — SnipKey could not read the snippet library already on this Mac and will not overwrite it. Open Settings to retry that file or start fresh, then import again."
            case .blockedByRemoteChange, .blockedByUnavailableLibrary, .blockedByNewerSchema:
                importSummary = "Nothing was imported — SnipKey will not write over the snippet library at its configured location. Quit and reopen SnipKey once the library is available, then import again."
            case .failed(let message):
                importSummary = "Nothing was imported. Saving failed: \(message)"
            }
        } catch {
            importSummary = "Import failed: \(error.localizedDescription)"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose a .textexpandersettings or .textexpanderbackup folder"
        if panel.runModal() == .OK, let url = panel.url {
            runImport(url)
        }
    }

    private func startFresh() {
        guard !store.isReadOnlyUntilRecovered else {
            importSummary = "SnipKey could not read the snippet library already on this Mac. Open Settings to retry that file or discard it before adding snippets."
            return
        }
        if !store.groups.contains(where: { $0.name == "Getting Started" }) {
            store.groups.append(Store.starterGroup())
        }
        switch store.saveNow() {
        case .saved:
            importSummary = "Added a “Getting Started” group with sample snippets."
        case .blockedByLoadFailure:
            importSummary = "SnipKey could not read the snippet library already on this Mac, so nothing was saved."
        case .blockedByRemoteChange, .blockedByUnavailableLibrary, .blockedByNewerSchema:
            importSummary = "SnipKey will not write over the snippet library at its configured location, so nothing was saved."
        case .failed(let message):
            importSummary = "Could not save the sample snippets: \(message)"
        }
    }

    // MARK: Step 4 — Try it

    private var tryIt: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("Try It Out")
                .font(.title.bold())

            if accessibilityGranted {
                Text("Type the abbreviation of any of your snippets in the box below —\nor in any other app. It expands the moment you finish typing it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Label("Grant Accessibility permission (step 2) first, then come back to try it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            TextField(placeholderAbbrev, text: $tryItText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(width: 360)

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick tips").font(.headline)
                Text("• The menu bar ⚡ icon opens your snippet library and settings.")
                Text("• Snippets with %filltext:…% pause and ask you to fill in the blanks.")
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
            return "Type \(first.abbreviation) here"
        }
        return "Type ;hello here"
    }
}
