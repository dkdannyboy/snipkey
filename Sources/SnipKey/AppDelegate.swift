import AppKit
import Combine
import SwiftUI
import SnipKeyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    /// 앱 전역에서 공유하는 단 하나의 현지화 관리자. SwiftUI 루트에는 EnvironmentObject로
    /// 주입하고, AppKit 조각(메인 메뉴·상태바·확장 엔진)에는 참조로 넘긴다.
    let loc = LocalizationManager()
    private var statusBar: StatusBarController!
    private var engine: ExpansionEngine!
    private var hotkeys: HotkeyManager!
    private var managerWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var engineStartTimer: Timer?
    /// 확장 횟수를 지켜보다 50배수마다 별표 프롬프트를 띄운다. 확장은 다른 앱에서
    /// 일어나므로 창이 닫혀 있어도 관측이 살아 있어야 한다.
    private var starPromptCancellable: AnyCancellable?
    /// GitHub 저장소 주소. 별표 버튼이 여기로 브라우저를 연다.
    private static let repoURL = URL(string: "https://github.com/dkdannyboy/snipkey")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched from \(Bundle.main.bundlePath) — accessibility trusted: \(ExpansionEngine.hasAccessibilityPermission)")
        MainMenu.install(loc: loc)
        engine = ExpansionEngine(store: store, loc: loc)
        hotkeys = HotkeyManager(store: store)
        statusBar = StatusBarController(
            store: store,
            loc: loc,
            openManager: { [weak self] in self?.showManager() },
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSearch: { [weak self] in self?.showInlineSearch() },
            openSettings: { [weak self] in self?.openSettings(nil) }
        )

        // 언어가 바뀌면 AppKit 메인 메뉴를 다시 그린다. SwiftUI는 @Published로 알아서
        // 갱신되고 상태바 메뉴는 열릴 때마다 새로 만들어지므로, 값 관찰을 하지 않는
        // 메인 메뉴만 여기서 손으로 다시 세운다.
        NotificationCenter.default.addObserver(
            forName: .snipKeyLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainMenu.install(loc: self.loc)
        }

        hotkeys.onInlineSearch = { [weak self] in self?.showInlineSearch() }
        hotkeys.registerAll()

        // 온보딩 완료 여부는 장치-로컬이다 — 접근성 권한이 Mac마다 따로 승인되므로,
        // 라이브러리를 물려받은 두 번째 Mac에서도 온보딩은 다시 돌아야 한다.
        if !store.didFinishOnboarding {
            showOnboarding()
        }

        startObservingStarPrompt()

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

    @objc func openSettings(_ sender: Any?) {
        showManager()
        NotificationCenter.default.post(name: .snipKeyOpenSettings, object: nil)
    }

    // MARK: - Star prompt

    /// 확장 횟수 변화를 구독한다. 결정은 순수 함수(StarPrompt)에 맡기고, 여기서는
    /// 결과에 따라 창을 띄우기만 한다. 결정 로직을 모델 밖으로 뺀 것은 테스트가 닿게
    /// 하기 위해서다 — NSAlert는 단위 테스트에서 돌릴 수 없다.
    private func startObservingStarPrompt() {
        starPromptCancellable = store.$expansionCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                guard let self else { return }
                guard StarPrompt.shouldPrompt(
                    expansionCount: count,
                    hasStarred: self.store.hasStarredOnGitHub,
                    dismissedForever: self.store.starPromptDismissedForever,
                    lastPromptedCount: self.store.starLastPromptedCount
                ) else { return }
                // 창을 실제로 띄우기 '전에' 못을 박는다. 그래야 같은 값에서 재실행하거나
                // 초기값이 다시 흘러도 창이 두 번 뜨지 않는다.
                self.store.starLastPromptedCount = count
                self.presentStarPrompt(expansionCount: count)
            }
    }

    private func presentStarPrompt(expansionCount: Int) {
        // 확장은 다른 앱을 쓰는 중에 일어난다. 창을 앞으로 가져오지 않으면 뒤에 묻혀
        // 사용자가 알림을 아예 못 본다.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = loc.s("star.title")
        alert.informativeText = loc.s("star.message", expansionCount)
        alert.addButton(withTitle: loc.s("star.button.star"))   // 첫 버튼 = 기본(Return)
        alert.addButton(withTitle: loc.s("star.button.later"))
        alert.addButton(withTitle: loc.s("star.button.never"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 별표를 눌렀다고 보고 프롬프트를 영원히 멈춘다. 실제 별표는 브라우저에서.
            store.hasStarredOnGitHub = true
            NSWorkspace.shared.open(Self.repoURL)
        case .alertThirdButtonReturn:
            store.starPromptDismissedForever = true
        default:
            // "Later" — 아무것도 저장하지 않는다. 다음 50배수에서 다시 뜬다.
            break
        }
    }

    // MARK: - Windows

    func showInlineSearch() {
        InlineSearchPanel.toggle(store: store, loc: loc) { [weak self] snippet, sourceApp in
            self?.engine.expandFromSearch(snippet, into: sourceApp)
        }
    }

    func showManager() {
        if managerWindow == nil {
            let view = ManagerView()
                .environmentObject(store)
                .environmentObject(loc)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = loc.s("window.main")
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
                    self.store.didFinishOnboarding = true
                    self.engine.startIfPossible()
                    self.onboardingWindow?.close()
                    self.showManager()
                }
            )
            .environmentObject(store)
            .environmentObject(loc)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = loc.s("onboarding.welcome.title")
            window.center()
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        presentWindow(onboardingWindow)
    }
}
