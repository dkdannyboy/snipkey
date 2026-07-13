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
        engine = ExpansionEngine(store: store)
        hotkeys = HotkeyManager(store: store)
        statusBar = StatusBarController(
            store: store,
            openManager: { [weak self] in self?.showManager() },
            openOnboarding: { [weak self] in self?.showOnboarding() }
        )

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

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Windows

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
        managerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
