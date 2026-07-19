import AppKit

/// Commands the manager window listens for. A menu-bar-only app starts with no
/// main menu at all, which means two things break: keyboard shortcuts declared
/// in SwiftUI never reliably fire, and — worse — the standard editing commands
/// (⌘C, ⌘V, ⌘A, undo) do not work inside text fields, because those are driven
/// by menu items. Building a real menu fixes both.
extension Notification.Name {
    static let snipKeyNewSnippet = Notification.Name("snipkey.command.newSnippet")
    static let snipKeyFocusSearch = Notification.Name("snipkey.command.focusSearch")
    // 설정은 지금껏 상태바 ⚡ → "Open SnipKey…" → Settings 탭 클릭으로만 닿을 수 있었다.
    // 표준 ⌘,가 없으면 사용자는 설정이 있는 줄도 모른다. 이 알림으로 창을 띄우고
    // Settings 탭을 고른다.
    static let snipKeyOpenSettings = Notification.Name("snipkey.command.openSettings")
}

enum MainMenu {

    static func install() {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())

        NSApp.mainMenu = mainMenu
    }

    // MARK: - App

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "SnipKey")
        // ⌘,는 창이 닫혀 있을 때도 눌린다. 그 순간엔 키 윈도우가 없어 자동 검증이
        // nil-타깃 항목을 꺼버릴 수 있으므로(File 메뉴가 같은 이유로 끈다), 자동 활성화를
        // 꺼서 Settings…가 항상 살아 있게 한다.
        menu.autoenablesItems = false

        menu.addItem(withTitle: "About SnipKey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // 타깃을 nil로 둔다 — AppKit이 응답자 사슬을 걸어 앱 델리게이트에 닿게 하고,
        // 그게 키 이퀴벌런트가 실제로 타는 경로다(newSnippet/focusSearch와 동일).
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        menu.addItem(settings)
        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide SnipKey", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(hide)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SnipKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.submenu = menu
        return item
    }

    // MARK: - File

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        // Leave the targets nil. AppKit then walks the responder chain, ending at
        // the app delegate — the standard route, and the one that key equivalents
        // actually take. An explicitly targeted item fires when clicked but gets
        // skipped during key-equivalent dispatch.
        menu.autoenablesItems = false

        let new = NSMenuItem(
            title: "New Snippet",
            action: #selector(AppDelegate.newSnippet(_:)),
            keyEquivalent: "n"
        )
        menu.addItem(new)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(close)

        item.submenu = menu
        return item
    }

    // MARK: - Edit

    /// The standard responder-chain editing commands. Without these, typing a
    /// snippet and pasting into it — the most basic thing the window is for —
    /// simply does not work.
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menu.addItem(.separator())

        let find = NSMenuItem(
            title: "Find Snippet",
            action: #selector(AppDelegate.focusSearch(_:)),
            keyEquivalent: "f"
        )
        menu.addItem(find)

        item.submenu = menu
        return item
    }

    // MARK: - Window

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
