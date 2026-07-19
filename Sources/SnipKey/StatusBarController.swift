import AppKit
import Combine
import SnipKeyKit

/// The menu bar item and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: Store
    private let openManager: () -> Void
    private let openOnboarding: () -> Void
    private let openSearch: () -> Void
    private let openSettings: () -> Void
    private var statusItem: NSStatusItem!

    init(
        store: Store,
        openManager: @escaping () -> Void,
        openOnboarding: @escaping () -> Void,
        openSearch: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.store = store
        self.openManager = openManager
        self.openOnboarding = openOnboarding
        self.openSearch = openSearch
        self.openSettings = openSettings
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bolt.square.fill",
                accessibilityDescription: "SnipKey"
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild the menu each time it opens so state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabled = store.settings.expansionEnabled
        let toggle = NSMenuItem(
            title: enabled ? "Expansion: On" : "Expansion: Off",
            action: #selector(toggleExpansion),
            keyEquivalent: "e"
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        if !ExpansionEngine.hasAccessibilityPermission {
            let warn = NSMenuItem(
                title: "⚠ Accessibility permission needed…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let search = NSMenuItem(
            title: "Search Snippets… (\(HotkeyFormatter.description(keyCode: store.settings.inlineSearchKeyCode, carbonModifiers: store.settings.inlineSearchModifiers)))",
            action: #selector(openInlineSearch),
            keyEquivalent: ""
        )
        search.target = self
        search.isEnabled = store.settings.inlineSearchEnabled
        menu.addItem(search)

        let open = NSMenuItem(title: "Open SnipKey…", action: #selector(openManagerWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        // 설정으로 가는 두 번째 문. 표준 ⌘, 메뉴가 창을 띄우고 Settings 탭을 고르는데,
        // 상태바에서도 같은 곳으로 바로 갈 수 있어야 발견 가능성이 올라간다.
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsTab), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let snippetCount = store.allSnippets.count
        let stats = NSMenuItem(
            title: "\(snippetCount) snippets · \(store.expansionCount) expansions",
            action: nil,
            keyEquivalent: ""
        )
        stats.isEnabled = false
        menu.addItem(stats)

        menu.addItem(.separator())

        let setup = NSMenuItem(title: "Setup Assistant…", action: #selector(openOnboardingWindow), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SnipKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleExpansion() {
        store.settings.expansionEnabled.toggle()
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
