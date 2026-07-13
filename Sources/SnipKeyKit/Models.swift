import Foundation

// MARK: - Snippet

public struct Snippet: Codable, Identifiable, Hashable {
    public var id: UUID
    public var abbreviation: String
    public var content: String
    public var label: String
    /// When false, the abbreviation matches regardless of letter case.
    public var caseSensitive: Bool
    public var enabled: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        abbreviation: String,
        content: String,
        label: String = "",
        caseSensitive: Bool = true,
        enabled: Bool = true,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.abbreviation = abbreviation
        self.content = content
        self.label = label
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Display title used in lists: label if present, else the abbreviation.
    public var displayTitle: String {
        label.isEmpty ? abbreviation : label
    }
}

// MARK: - SnippetGroup

public struct SnippetGroup: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var snippets: [Snippet]

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, snippets: [Snippet] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.snippets = snippets
    }
}

// MARK: - Hotkey macros (Keyboard Maestro-style)

public enum MacroActionKind: String, Codable, CaseIterable, Identifiable {
    case insertText
    case runShellScript
    case runAppleScript
    case openURL
    case openApp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .insertText: return "Insert Text"
        case .runShellScript: return "Run Shell Script"
        case .runAppleScript: return "Run AppleScript"
        case .openURL: return "Open URL"
        case .openApp: return "Open Application"
        }
    }
}

public struct HotkeyMacro: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Carbon virtual key code.
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey/optionKey/controlKey/shiftKey).
    public var modifiers: UInt32
    public var kind: MacroActionKind
    /// The action payload: text to insert, script source, URL, or app name/path.
    public var argument: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        keyCode: UInt32 = 0,
        modifiers: UInt32 = 0,
        kind: MacroActionKind = .insertText,
        argument: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.kind = kind
        self.argument = argument
        self.enabled = enabled
    }

    public var hasHotkey: Bool { keyCode != 0 || modifiers != 0 }
}

// MARK: - Settings

public struct AppSettings: Codable, Hashable {
    public var expansionEnabled: Bool
    public var playSoundOnExpand: Bool
    public var didFinishOnboarding: Bool
    /// Seconds to wait before restoring the clipboard after a paste-expansion.
    public var clipboardRestoreDelay: Double

    public init(
        expansionEnabled: Bool = true,
        playSoundOnExpand: Bool = true,
        didFinishOnboarding: Bool = false,
        clipboardRestoreDelay: Double = 0.35
    ) {
        self.expansionEnabled = expansionEnabled
        self.playSoundOnExpand = playSoundOnExpand
        self.didFinishOnboarding = didFinishOnboarding
        self.clipboardRestoreDelay = clipboardRestoreDelay
    }
}

// MARK: - Persisted document

public struct StoreData: Codable {
    public var version: Int
    public var groups: [SnippetGroup]
    public var macros: [HotkeyMacro]
    public var settings: AppSettings
    /// Lifetime count of expansions, for the fun statistic.
    public var expansionCount: Int

    public init(
        version: Int = 1,
        groups: [SnippetGroup] = [],
        macros: [HotkeyMacro] = [],
        settings: AppSettings = AppSettings(),
        expansionCount: Int = 0
    ) {
        self.version = version
        self.groups = groups
        self.macros = macros
        self.settings = settings
        self.expansionCount = expansionCount
    }
}
