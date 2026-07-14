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

    /// What happened when a save was attempted. Anything that reports success to
    /// the user must look at this rather than assuming the write landed.
    public enum SaveOutcome: Equatable {
        case saved
        /// The existing store could not be read, so writing would destroy it.
        case blockedByLoadFailure
        case failed(String)

        public var didSave: Bool { self == .saved }
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

        /// 유니코드 기준 단어 문자. ASCII만 보면 한글·일본어·악센트 라틴이
        /// 전부 "경계"로 잘못 분류돼서, 단어 한가운데서 확장이 터진다.
        static func isWordCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        /// Finds the longest enabled abbreviation that is a suffix of `buffer`,
        /// requiring a word boundary before word-initial abbreviations.
        public func match(buffer: String) -> Snippet? {
            guard maxLength > 0, !buffer.isEmpty else { return nil }
            let chars = Array(buffer)
            let upper = min(maxLength, chars.count)
            // Longest match wins, mirroring TextExpander behavior.
            for len in stride(from: upper, through: 1, by: -1) {
                let start = chars.count - len
                let suffix = String(chars[start...])
                guard let snippet = exact[suffix] ?? insensitive[suffix.lowercased()] else {
                    continue
                }

                // 단어 경계 검사. 약어가 단어 문자로 시작하는데 바로 앞 글자도
                // 단어 문자라면, 사용자는 약어가 아니라 더 긴 단어를 치는 중이다
                // ('sig' 스니펫을 둔 채 'design'을 치는 경우). 여기서 발화하면
                // 아직 도착하지 않은 키와 백스페이스가 경합해 사용자가 친 글자를
                // 비결정적으로 파괴한다.
                //
                // ';sig', '/addr' 처럼 구두점으로 시작하는 약어는 그 자체로 경계라
                // 검사에서 제외한다 — 글자 바로 뒤에 와도 지금처럼 확장된다.
                if Self.isWordCharacter(chars[start]),
                   start > 0,
                   Self.isWordCharacter(chars[start - 1]) {
                    // 더 짧은 접미사가 여전히 정당한 매치일 수 있으므로 스캔을 계속한다.
                    continue
                }
                return snippet
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

    /// 저장소 파일 경로를 강제로 바꾸는 환경변수. E2E 하네스가 사용자의 실제
    /// 스니펫 라이브러리 대신 일회용 저장소를 쓰게 하는 유일한 통로다.
    public static let storeDirEnvKey = "SNIPKEY_STORE_DIR"

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // 테스트 격리용 오버라이드. 값이 비어 있으면 설정하지 않은 것으로 본다 —
        // 빈 문자열을 그대로 받아들이면 "/store.json"을 가리키게 된다.
        if let dir = environment[storeDirEnvKey], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("store.json")
        }
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

    /// True while the store file could not be read. No change can be persisted
    /// until the user recovers or explicitly starts fresh.
    public var isReadOnlyUntilRecovered: Bool { loadFailure != nil }

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

    /// Merges imported groups and writes them, reporting whether the import
    /// actually reached disk. Migration is the one place where "it looked like
    /// it worked" is the worst possible outcome, so this refuses to run at all
    /// while the store is unreadable — importing into an in-memory library that
    /// can never be saved would quietly lose the user's snippets.
    @discardableResult
    public func importGroups(_ imported: [SnippetGroup]) -> SaveOutcome {
        guard !isReadOnlyUntilRecovered else { return .blockedByLoadFailure }
        mergeImported(groups: imported)
        return saveNow()
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

    /// Copies the current state. Must run on whatever thread owns the store's
    /// properties (the main thread in the app), never on the save queue — the
    /// background writer must encode an immutable snapshot, not live arrays the
    /// UI may be mutating underneath it.
    private func snapshot() -> StoreData {
        StoreData(
            groups: groups,
            macros: macros,
            settings: settings,
            expansionCount: expansionCount
        )
    }

    private func snapshotFromAnyThread() -> StoreData {
        if Thread.isMainThread { return snapshot() }
        return DispatchQueue.main.sync { self.snapshot() }
    }

    /// Called from the property observers, i.e. on the thread that made the
    /// change. The snapshot is taken here, so the queued write cannot race with
    /// further edits.
    private func scheduleSave() {
        guard !isSavingBlocked else { return }
        let data = snapshot()
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in _ = self?.write(data) }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Writes immediately and reports what happened. Callers that tell the user
    /// something was saved — importing, in particular — must check this.
    @discardableResult
    public func saveNow() -> SaveOutcome {
        // Refuse to write over a store we could not read. Overwriting it would
        // destroy whatever snippets it still holds.
        guard !isSavingBlocked else { return .blockedByLoadFailure }
        let data = snapshotFromAnyThread()
        saveWorkItem?.cancel()
        return saveQueue.sync { write(data) }
    }

    private func write(_ data: StoreData) -> SaveOutcome {
        guard !isSavingBlocked else { return .blockedByLoadFailure }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = try JSONEncoder.snipKey.encode(data)
            try raw.write(to: fileURL, options: .atomic)
            return .saved
        } catch {
            NSLog("SnipKey: failed to save store: \(error)")
            return .failed(error.localizedDescription)
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
