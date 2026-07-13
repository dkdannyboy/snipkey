import Foundation

/// Observable persistence layer. Loads/saves a single JSON document under
/// ~/Library/Application Support/SnipKey/store.json and keeps a fast
/// abbreviation index for the expansion engine.
public final class Store: ObservableObject {

    /// The store file exists but could not be read or decoded. Saving is blocked
    /// while this is set, so a transient read error or a half-written file can
    /// never be "recovered" by silently overwriting the user's library with an
    /// empty one.
    public struct LoadFailure: Equatable {
        public let message: String
        public let originalURL: URL
        /// A copy of the unreadable file, if one could be made.
        public let backupURL: URL?
    }

    @Published public var groups: [SnippetGroup] { didSet { scheduleSave(); rebuildIndex() } }
    @Published public var macros: [HotkeyMacro] { didSet { scheduleSave() } }
    @Published public var settings: AppSettings { didSet { scheduleSave() } }
    @Published public private(set) var expansionCount: Int
    @Published public private(set) var loadFailure: LoadFailure?

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "snipkey.store.save")
    /// Read from the save queue, so it is guarded rather than read off @Published.
    private let savesBlockedLock = NSLock()
    private var savesBlocked = false
    private var isSavingBlocked: Bool {
        savesBlockedLock.lock()
        defer { savesBlockedLock.unlock() }
        return savesBlocked
    }

    /// Snapshot used by the expansion engine (read from the event-tap thread).
    public struct Matcher {
        public let maxLength: Int
        /// abbreviation (exact) -> snippet
        public let exact: [String: Snippet]
        /// lowercased abbreviation -> snippet, for case-insensitive snippets
        public let insensitive: [String: Snippet]

        /// Finds the longest enabled abbreviation that is a suffix of `buffer`.
        public func match(buffer: String) -> Snippet? {
            guard maxLength > 0, !buffer.isEmpty else { return nil }
            let chars = Array(buffer)
            let upper = min(maxLength, chars.count)
            // Longest match wins, mirroring TextExpander behavior.
            for len in stride(from: upper, through: 1, by: -1) {
                let suffix = String(chars[(chars.count - len)...])
                if let s = exact[suffix] { return s }
                if let s = insensitive[suffix.lowercased()] { return s }
            }
            return nil
        }
    }

    private let matcherLock = NSLock()
    private var _matcher = Matcher(maxLength: 0, exact: [:], insensitive: [:])
    public var matcher: Matcher {
        matcherLock.lock()
        defer { matcherLock.unlock() }
        return _matcher
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SnipKey/store.json")
    }

    public init(fileURL: URL = Store.defaultFileURL()) {
        self.fileURL = fileURL

        var data = StoreData()
        var failure: LoadFailure?

        // A missing file is a first launch. A file that exists but will not read
        // or decode is something else entirely — possibly the user's whole
        // snippet library. Never treat that as "empty and ready to overwrite".
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let raw = try Data(contentsOf: fileURL)
                data = try JSONDecoder.snipKey.decode(StoreData.self, from: raw)
            } catch {
                let backup = Self.backUpUnreadableFile(at: fileURL)
                failure = LoadFailure(
                    message: error.localizedDescription,
                    originalURL: fileURL,
                    backupURL: backup
                )
            }
        }

        self.groups = data.groups
        self.macros = data.macros
        self.settings = data.settings
        self.expansionCount = data.expansionCount
        self.loadFailure = failure
        self.savesBlocked = failure != nil
        rebuildIndex()
    }

    /// Copies (does not move) an unreadable store next to the original, so the
    /// user's data survives even if they later choose to start fresh.
    private static func backUpUnreadableFile(at url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("store-unreadable-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    // MARK: - Load failure recovery

    /// Abandons the unreadable file and starts from an empty library. The
    /// backup copy is left in place. Saving resumes after this.
    public func startFreshDiscardingUnreadableStore() {
        guard loadFailure != nil else { return }
        loadFailure = nil
        savesBlockedLock.lock()
        savesBlocked = false
        savesBlockedLock.unlock()
        groups = []
        macros = []
        saveNow()
    }

    /// Retries reading the file — for when the user has repaired or replaced it
    /// by hand. Returns true if the store loaded.
    @discardableResult
    public func retryLoadingStore() -> Bool {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.snipKey.decode(StoreData.self, from: raw)
        else { return false }

        loadFailure = nil
        savesBlockedLock.lock()
        savesBlocked = false
        savesBlockedLock.unlock()
        settings = decoded.settings
        macros = decoded.macros
        expansionCount = decoded.expansionCount
        groups = decoded.groups // last: its didSet rebuilds the matcher and saves
        return true
    }

    // MARK: - Lookup helpers

    public var allSnippets: [Snippet] {
        groups.flatMap(\.snippets)
    }

    public func snippet(forAbbreviation abbrev: String) -> Snippet? {
        for group in groups where group.enabled {
            if let s = group.snippets.first(where: { $0.abbreviation == abbrev }) {
                return s
            }
        }
        return nil
    }

    public func recordExpansion() {
        DispatchQueue.main.async {
            self.expansionCount += 1
            self.scheduleSave()
        }
    }

    // MARK: - Mutation helpers

    public func addGroup(named name: String) -> SnippetGroup {
        let g = SnippetGroup(name: name)
        groups.append(g)
        return g
    }

    public func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    public func groupIndex(of id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    public func updateSnippet(_ snippet: Snippet, inGroup groupID: UUID) {
        guard let gi = groupIndex(of: groupID) else { return }
        if let si = groups[gi].snippets.firstIndex(where: { $0.id == snippet.id }) {
            groups[gi].snippets[si] = snippet
        } else {
            groups[gi].snippets.append(snippet)
        }
    }

    public func removeSnippet(id: UUID, fromGroup groupID: UUID) {
        guard let gi = groupIndex(of: groupID) else { return }
        groups[gi].snippets.removeAll { $0.id == id }
    }

    /// Merges imported groups. Groups with the same name are replaced.
    public func mergeImported(groups imported: [SnippetGroup]) {
        var current = groups
        for g in imported {
            if let idx = current.firstIndex(where: { $0.name == g.name }) {
                current[idx] = g
            } else {
                current.append(g)
            }
        }
        groups = current
    }

    // MARK: - Persistence

    private func rebuildIndex() {
        var exact: [String: Snippet] = [:]
        var insensitive: [String: Snippet] = [:]
        var maxLen = 0
        for group in groups where group.enabled {
            for s in group.snippets where s.enabled && !s.abbreviation.isEmpty {
                maxLen = max(maxLen, s.abbreviation.count)
                if s.caseSensitive {
                    exact[s.abbreviation] = s
                } else {
                    insensitive[s.abbreviation.lowercased()] = s
                }
            }
        }
        matcherLock.lock()
        _matcher = Matcher(maxLength: maxLen, exact: exact, insensitive: insensitive)
        matcherLock.unlock()
    }

    private func scheduleSave() {
        guard !isSavingBlocked else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    public func saveNow() {
        // Refuse to write over a store we could not read. Overwriting it would
        // destroy whatever snippets it still holds.
        guard !isSavingBlocked else {
            NSLog("SnipKey: save skipped — the existing store could not be read")
            return
        }
        let data = StoreData(
            groups: groups,
            macros: macros,
            settings: settings,
            expansionCount: expansionCount
        )
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = try JSONEncoder.snipKey.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SnipKey: failed to save store: \(error)")
        }
    }

    // MARK: - Starter content for new users

    public static func starterGroup(email: String? = nil) -> SnippetGroup {
        var snippets: [Snippet] = [
            Snippet(
                abbreviation: ";hello",
                content: "Hello from SnipKey! 👋",
                label: "Try me"
            ),
            Snippet(
                abbreviation: ";date",
                content: "%date:yyyy-MM-dd%",
                label: "Today's date"
            ),
            Snippet(
                abbreviation: ";time",
                content: "%date:HH:mm%",
                label: "Current time"
            ),
            Snippet(
                abbreviation: ";sig",
                content: "Best regards,\n%filltext:name=Your name%",
                label: "Email signature (fill-in demo)"
            ),
        ]
        if let email {
            snippets.insert(
                Snippet(abbreviation: ";em", content: email, label: "My email"),
                at: 0
            )
        }
        return SnippetGroup(name: "Getting Started", snippets: snippets)
    }
}

// MARK: - JSON coding configuration

extension JSONEncoder {
    static var snipKey: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var snipKey: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
