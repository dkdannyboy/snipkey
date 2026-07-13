import AppKit
import Combine
import SnipKeyKit

/// The menu bar item and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: Store
    private let openManager: () -> Void
    private let openOnboarding: () -> Void
    private var statusItem: NSStatusItem!

    init(store: Store, openManager: @escaping () -> Void, openOnboarding: @escaping () -> Void) {
        self.store = store
        self.openManager = openManager
        self.openOnboarding = openOnboarding
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

        let open = NSMenuItem(title: "Open SnipKey…", action: #selector(openManagerWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

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
        openManager()
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
