import AppKit
import Carbon.HIToolbox
import Combine
import SnipKeyKit

/// The menu bar item and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: Store
    private let loc: LocalizationManager
    private let openManager: () -> Void
    private let openOnboarding: () -> Void
    private let openSearch: () -> Void
    private let openSettings: () -> Void
    private var statusItem: NSStatusItem!
    /// 설정 변경 경로(토글·설정 탭·iCloud 동기화) 어디서 와도 아이콘이 즉시 반영되도록.
    private var cancellables = Set<AnyCancellable>()

    init(
        store: Store,
        loc: LocalizationManager,
        openManager: @escaping () -> Void,
        openOnboarding: @escaping () -> Void,
        openSearch: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.loc = loc
        self.openManager = openManager
        self.openOnboarding = openOnboarding
        self.openSearch = openSearch
        self.openSettings = openSettings
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // 확장이 꺼져 있으면 아이콘도 즉시 비어 보이게 한다 — 메뉴를 열어보지 않아도
        // 한눈에 꺼진 걸 알 수 있어야, "언제 꺼졌는지도 몰랐다"는 일이 안 생긴다.
        // 언어가 바뀌어도 다시 그린다 — 아이콘의 접근성 레이블(VoiceOver가 읽는 말)도
        // 현지화 문자열이라, 켜짐/꺼짐이 그대로여도 새 언어로 바뀌어야 한다.
        store.$settings
            .map(\.expansionEnabled)
            .removeDuplicates()
            .combineLatest(loc.$language)
            .sink { [weak self] enabled, _ in self?.updateIcon(enabled: enabled) }
            .store(in: &cancellables)
    }

    private func updateIcon(enabled: Bool) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: enabled ? "bolt.square.fill" : "bolt.square",
            accessibilityDescription: enabled ? loc.s("status.expansionOn") : loc.s("status.expansionOff")
        )
    }

    // Rebuild the menu each time it opens so state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabled = store.settings.expansionEnabled
        let toggle = NSMenuItem(
            title: enabled ? loc.s("status.expansionOn") : loc.s("status.expansionOff"),
            action: #selector(toggleExpansion),
            keyEquivalent: "e"
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        // 상태바 메뉴는 SnipKey를 앞으로 가져오지 않으므로, 지금 맨 앞 앱이 곧 사용자가
        // 방금까지 쓰던 앱이다. 거기서 바로 "이 앱에서는 확장 안 함"을 켜고 끌 수 있게 한다.
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let excluded = store.settings.isExcluded(bundleID: bundleID)
            let item = NSMenuItem(
                title: loc.s("status.excludeApp", name),
                action: #selector(toggleAppExclusion(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bundleID
            item.state = excluded ? .on : .off
            menu.addItem(item)
        }

        // 비밀번호 칸 등에서 다른 앱이 보안 입력을 켜면 macOS가 키 입력을 아예 보여 주지
        // 않는다 — 확장이 '고장'처럼 보이는 가장 흔한 원인이라, 그 사실을 알려 준다.
        if IsSecureEventInputEnabled() {
            let secure = NSMenuItem(title: loc.s("status.secureInput"), action: nil, keyEquivalent: "")
            secure.isEnabled = false
            menu.addItem(secure)
        }

        if !ExpansionEngine.hasAccessibilityPermission {
            let warn = NSMenuItem(
                title: loc.s("status.accessibilityNeeded"),
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let shortcut = HotkeyFormatter.description(
            keyCode: store.settings.inlineSearchKeyCode,
            carbonModifiers: store.settings.inlineSearchModifiers
        )
        let search = NSMenuItem(
            title: loc.s("status.searchSnippets", shortcut),
            action: #selector(openInlineSearch),
            keyEquivalent: ""
        )
        search.target = self
        search.isEnabled = store.settings.inlineSearchEnabled
        menu.addItem(search)

        let open = NSMenuItem(title: loc.s("status.openSnipKey"), action: #selector(openManagerWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        // 설정으로 가는 두 번째 문. 표준 ⌘, 메뉴가 창을 띄우고 Settings 탭을 고르는데,
        // 상태바에서도 같은 곳으로 바로 갈 수 있어야 발견 가능성이 올라간다.
        let settings = NSMenuItem(title: loc.s("menu.settings"), action: #selector(openSettingsTab), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let stats = NSMenuItem(
            title: loc.s("status.stats", store.allSnippets.count, store.expansionCount),
            action: nil,
            keyEquivalent: ""
        )
        stats.isEnabled = false
        menu.addItem(stats)

        menu.addItem(.separator())

        let setup = NSMenuItem(title: loc.s("status.setupAssistant"), action: #selector(openOnboardingWindow), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: loc.s("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleExpansion() {
        store.settings.expansionEnabled.toggle()
    }

    @objc private func toggleAppExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if let index = store.settings.excludedBundleIDs.firstIndex(of: bundleID) {
            store.settings.excludedBundleIDs.remove(at: index)
        } else {
            store.settings.excludedBundleIDs.append(bundleID)
        }
    }

    @objc private func openManagerWindow() {
        DispatchQueue.main.async { [openManager] in
            openManager()
        }
    }

    @objc private func openInlineSearch() {
        openSearch()
    }

    @objc private func openSettingsTab() {
        openSettings()
    }

    @objc private func openOnboardingWindow() {
        openOnboarding()
    }

    @objc private func openAccessibilitySettings() {
        // The Setup Assistant explains the permission and offers the recovery
        // path for stale grants after an update.
        openOnboarding()
    }
}
