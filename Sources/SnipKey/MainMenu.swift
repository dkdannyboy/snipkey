import AppKit

/// Commands the manager window listens for. A menu-bar-only app starts with no
/// main menu at all, which means two things break: keyboard shortcuts declared
/// in SwiftUI never reliably fire, and — worse — the standard editing commands
/// (⌘C, ⌘V, ⌘A, undo) do not work inside text fields, because those are driven
/// by menu items. Building a real menu fixes both.
extension Notification.Name {
    static let snipKeyNewSnippet = Notification.Name("snipkey.command.newSnippet")
    static let snipKeyFocusSearch = Notification.Name("snipkey.command.focusSearch")
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

        menu.addItem(withTitle: "About SnipKey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
