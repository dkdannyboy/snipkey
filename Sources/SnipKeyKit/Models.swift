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
    /// **이 빌드는 이 값을 읽지 않는다** — 온보딩 완료 여부는 `Store.didFinishOnboarding`,
    /// 즉 UserDefaults에 있다. 접근성 권한이 Mac마다 따로 승인되므로 두 번째 Mac에서는
    /// 온보딩이 다시 떠야 한다. 키는 pre-2.0 빌드와의 호환을 위해 남긴다.
    public var didFinishOnboarding: Bool
    /// Seconds to wait before restoring the clipboard after a paste-expansion.
    public var clipboardRestoreDelay: Double

    /// Search-anywhere palette. Defaults to ⌘/ — the same shortcut TextExpander
    /// uses for its inline search.
    public var inlineSearchEnabled: Bool
    public var inlineSearchKeyCode: UInt32
    public var inlineSearchModifiers: UInt32

    public init(
        expansionEnabled: Bool = true,
        playSoundOnExpand: Bool = true,
        didFinishOnboarding: Bool = false,
        clipboardRestoreDelay: Double = 0.35,
        inlineSearchEnabled: Bool = true,
        inlineSearchKeyCode: UInt32 = 44,   // kVK_ANSI_Slash
        inlineSearchModifiers: UInt32 = 256 // cmdKey
    ) {
        self.expansionEnabled = expansionEnabled
        self.playSoundOnExpand = playSoundOnExpand
        self.didFinishOnboarding = didFinishOnboarding
        self.clipboardRestoreDelay = clipboardRestoreDelay
        self.inlineSearchEnabled = inlineSearchEnabled
        self.inlineSearchKeyCode = inlineSearchKeyCode
        self.inlineSearchModifiers = inlineSearchModifiers
    }

    // Older stores predate the inline-search keys; fall back to the defaults
    // rather than failing to decode the user's whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        expansionEnabled = try c.decodeIfPresent(Bool.self, forKey: .expansionEnabled) ?? defaults.expansionEnabled
        playSoundOnExpand = try c.decodeIfPresent(Bool.self, forKey: .playSoundOnExpand) ?? defaults.playSoundOnExpand
        didFinishOnboarding = try c.decodeIfPresent(Bool.self, forKey: .didFinishOnboarding) ?? defaults.didFinishOnboarding
        clipboardRestoreDelay = try c.decodeIfPresent(Double.self, forKey: .clipboardRestoreDelay) ?? defaults.clipboardRestoreDelay
        inlineSearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .inlineSearchEnabled) ?? defaults.inlineSearchEnabled
        inlineSearchKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .inlineSearchKeyCode) ?? defaults.inlineSearchKeyCode
        inlineSearchModifiers = try c.decodeIfPresent(UInt32.self, forKey: .inlineSearchModifiers) ?? defaults.inlineSearchModifiers
    }
}

// MARK: - Persisted document

public struct StoreData: Codable {
    /// 이 빌드가 이해하는 최상위 스키마 버전. 이보다 높은 파일은 다른(더 새로운)
    /// Mac이 쓴 것이므로 건드리지 않는다 — `Store.init`의 버전 검사 참조.
    public static let currentVersion = 2

    public var version: Int
    public var groups: [SnippetGroup]
    public var macros: [HotkeyMacro]
    public var settings: AppSettings
    /// **이 빌드는 이 값을 읽지 않는다.** 확장 통계는 Mac마다 따로 세므로
    /// UserDefaults에 있다. 그런데도 계속 써 넣는 이유는 하나다: pre-2.0 빌드의
    /// `StoreData`는 합성 Codable에 비옵셔널 `expansionCount`라서, 이 키를 빼면
    /// 구버전 앱이 **라이브러리 전체를** 디코드하지 못한다. 동기화되는 파일은 서로
    /// 다른 앱 버전의 두 Mac이 함께 만지므로, 그쪽 Mac이 통째로 loadFailure에
    /// 빠진다. 값은 무의미하고 Mac 사이에서 오락가락해도 무해하다.
    /// pre-2.0 빌드가 사라지면 지워도 된다.
    public var expansionCount: Int

    public init(
        version: Int = StoreData.currentVersion,
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

    /// 관용적 디코더. `AppSettings.init(from:)`이 이미 같은 이유로 같은 모양을
    /// 하고 있다 — 키 하나가 없다고 사용자의 라이브러리 전체를 못 읽는 것보다는
    /// 기본값으로 물러나는 편이 낫다. 동기화 파일에서는 이게 더 절실하다:
    /// 두 Mac의 앱 버전이 다르면 스키마가 갈라지는 게 정상이기 때문이다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StoreData()
        // 버전 키가 아예 없는 파일은 버전 필드가 생기기 전의 것이다. 그걸
        // currentVersion으로 읽으면 옛 파일이 최신인 척하게 되므로 1로 본다.
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try c.decodeIfPresent([SnippetGroup].self, forKey: .groups) ?? defaults.groups
        macros = try c.decodeIfPresent([HotkeyMacro].self, forKey: .macros) ?? defaults.macros
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? defaults.settings
        expansionCount = try c.decodeIfPresent(Int.self, forKey: .expansionCount) ?? defaults.expansionCount
    }
}
