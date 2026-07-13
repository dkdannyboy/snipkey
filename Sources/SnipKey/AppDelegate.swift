import AppKit
import SwiftUI
import SnipKeyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var statusBar: StatusBarController!
    private var engine: ExpansionEngine!
    private var hotkeys: HotkeyManager!
    private var managerWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var engineStartTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched from \(Bundle.main.bundlePath) — accessibility trusted: \(ExpansionEngine.hasAccessibilityPermission)")
        MainMenu.install()
        engine = ExpansionEngine(store: store)
        hotkeys = HotkeyManager(store: store)
        statusBar = StatusBarController(
            store: store,
            openManager: { [weak self] in self?.showManager() },
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSearch: { [weak self] in self?.showInlineSearch() }
        )

        hotkeys.onInlineSearch = { [weak self] in self?.showInlineSearch() }
        hotkeys.registerAll()

        if !store.settings.didFinishOnboarding {
            showOnboarding()
        }

        // Start the engine as soon as Accessibility permission is available,
        // whenever the user grants it.
        startEngineIfPossible()
        engineStartTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.startEngineIfPossible()
            if self.engine.isRunning { timer.invalidate() }
        }
    }

    func startEngineIfPossible() {
        engine.startIfPossible()
    }

    /// SnipKey keeps running in the menu bar after its window is closed — that
    /// is the whole point of it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Menu commands
    //
    // Reached through the responder chain from the main menu, so ⌘N and ⌘F work
    // as key equivalents. The views listen for these notifications.

    @objc func newSnippet(_ sender: Any?) {
        showManager()
        NotificationCenter.default.post(name: .snipKeyNewSnippet, object: nil)
    }

    @objc func focusSearch(_ sender: Any?) {
        showManager()
        NotificationCenter.default.post(name: .snipKeyFocusSearch, object: nil)
    }

    // MARK: - Windows

    func showInlineSearch() {
        InlineSearchPanel.toggle(store: store) { [weak self] snippet, sourceApp in
            self?.engine.expandFromSearch(snippet, into: sourceApp)
        }
    }

    func showManager() {
        if managerWindow == nil {
            let view = ManagerView()
                .environmentObject(store)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SnipKey"
            window.center()
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            managerWindow = window
        }
        presentWindow(managerWindow)
    }

    /// Brings a window forward and gives it keyboard focus. The app is `.regular`
    /// (see main.swift), so this is just the ordinary AppKit dance — no
    /// activation-policy juggling, which is exactly why it is dependable.
    ///
    /// Deferring by one turn of the run loop lets the status-bar menu finish
    /// closing first; ordering a window front while a menu is still tracking
    /// leaves the window visible but unfocused.
    private func presentWindow(_ window: NSWindow?) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.store.settings.didFinishOnboarding = true
                    self.engine.startIfPossible()
                    self.onboardingWindow?.close()
                    self.showManager()
                }
            )
            .environmentObject(store)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to SnipKey"
            window.center()
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        presentWindow(onboardingWindow)
    }
}
