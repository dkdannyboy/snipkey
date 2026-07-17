import CryptoKit
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
    ///
    /// 차단 케이스가 여럿인 것은 우연이 아니다. 이 저장소의 규칙은 하나다 —
    /// **읽지 못했거나, 우리가 아는 것이 아닌 파일은 절대 덮지 않는다.** 아래 각
    /// 케이스는 그 규칙이 걸리는 서로 다른 이유이고, 어느 것도 앱이 승자를 골라서
    /// 해소하지 않는다.
    public enum SaveOutcome: Equatable {
        case saved
        /// The existing store could not be read, so writing would destroy it.
        case blockedByLoadFailure
        /// 마지막으로 읽은 뒤 디스크의 파일이 바뀌었다. 다른 Mac이 편집했다는 뜻이고,
        /// 우리 스냅샷은 이미 낡았다. 그대로 쓰면 저쪽 편집이 조용히 사라진다.
        case blockedByRemoteChange
        /// 사용자가 지정한 위치에 라이브러리가 있어야 하는데 없다. iCloud가 아직
        /// 내려받지 않았거나 볼륨이 빠진 것이지, 빈 라이브러리로 시작할 때가 아니다.
        case blockedByUnavailableLibrary
        /// 더 새로운 빌드가 쓴 파일이다. 우리가 모르는 필드를 들고 있으므로,
        /// 우리 스키마로 다시 쓰면 그 필드가 조용히 사라진다 = 다운그레이드.
        case blockedByNewerSchema
        case failed(String)

        public var didSave: Bool { self == .saved }
    }

    /// 저장소 파일 내용의 지문. "파일이 없었다"와 "이런 내용이었다"는 다른 상태다 —
    /// 없던 파일이 생긴 것도 원격 변경이므로 옵셔널로 뭉개면 안 된다.
    enum FileDigest: Equatable {
        case absent
        /// 파일은 있는데 읽을 수 없다 (권한, 또는 아직 실체화되지 않은 iCloud 자리표시자).
        case unreadable
        case sha(String)
    }

    /// 저장소 파일의 경로와, **그 경로에 라이브러리가 이미 있어야 하는가**.
    /// 두 번째 값이 이 타입의 존재 이유다. `~/Library/Application Support`의 파일
    /// 부재와, 사용자가 직접 고른 동기화 폴더의 파일 부재는 정반대의 뜻이다.
    public struct Location: Equatable {
        public let fileURL: URL
        /// 사용자가 명시적으로 고른 위치인가. 그렇다면 파일이 없다는 것은
        /// "첫 실행"이 아니라 "아직 못 받았다"는 뜻이다.
        public let expectsExistingLibrary: Bool

        public init(fileURL: URL, expectsExistingLibrary: Bool) {
            self.fileURL = fileURL
            self.expectsExistingLibrary = expectsExistingLibrary
        }
    }

    /// 장치-로컬 상태의 UserDefaults 키. 이 값들은 **동기화되는 문서에 들어가면
    /// 안 된다.** 저장소 위치 포인터는 닭-달걀이라 store.json 안에 둘 수 없고,
    /// 확장 횟수는 Mac마다 다르며 파일에 있으면 확장 한 번마다 파일이 더러워진다.
    public enum DeviceStateKey {
        public static let expansionCount = "SnipKey.device.expansionCount"
        public static let didFinishOnboarding = "SnipKey.device.didFinishOnboarding"
        public static let storeLocationPath = "SnipKey.storeLocationPath"
    }

    @Published public var groups: [SnippetGroup] { didSet { scheduleSave(); rebuildIndex() } }
    @Published public var macros: [HotkeyMacro] { didSet { scheduleSave() } }
    @Published public var settings: AppSettings { didSet { scheduleSave() } }
    /// 장치-로컬. 파일이 아니라 UserDefaults가 권위다.
    @Published public private(set) var expansionCount: Int
    /// 장치-로컬. 접근성 권한이 Mac마다 따로 승인되므로, 라이브러리를 물려받은
    /// 두 번째 Mac에서도 온보딩은 처음부터 다시 돌아야 한다.
    @Published public var didFinishOnboarding: Bool {
        didSet { deviceDefaults.set(didFinishOnboarding, forKey: DeviceStateKey.didFinishOnboarding) }
    }
    @Published public private(set) var loadFailure: LoadFailure?
    /// 있어야 할 라이브러리가 아직 없다. 빈 라이브러리를 사용자의 진짜 것인 양
    /// 보여주면 안 되는 상태다.
    @Published public private(set) var isLibraryUnavailable: Bool

    private let fileURL: URL
    /// 파일 부재를 첫 실행으로 볼 것인가, 사용 불가로 볼 것인가.
    private let expectsExistingLibrary: Bool
    private let deviceDefaults: UserDefaults
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "snipkey.store.save")
    /// Read from the save queue, so it is guarded rather than read off @Published.
    private let savesBlockedLock = NSLock()
    private var savesBlocked: SaveOutcome?
    /// 저장이 막혀 있다면 그 이유. 이유를 들고 다녀야 호출자에게 무엇이 막았는지
    /// 그대로 돌려줄 수 있다.
    private var blockedReason: SaveOutcome? {
        savesBlockedLock.lock()
        defer { savesBlockedLock.unlock() }
        return savesBlocked
    }
    private var isSavingBlocked: Bool { blockedReason != nil }
    private func setBlockedReason(_ reason: SaveOutcome?) {
        savesBlockedLock.lock()
        savesBlocked = reason
        savesBlockedLock.unlock()
    }

    /// 마지막으로 성공적으로 읽거나 쓴 파일의 지문. 저장 전에 디스크와 비교하는
    /// 기준값이다. 저장 큐에서 읽으므로 잠근다.
    private let digestLock = NSLock()
    private var savedDigest: FileDigest = .absent
    private var lastKnownDigest: FileDigest {
        digestLock.lock()
        defer { digestLock.unlock() }
        return savedDigest
    }
    private func setLastKnownDigest(_ digest: FileDigest) {
        digestLock.lock()
        savedDigest = digest
        digestLock.unlock()
    }

    /// Snapshot used by the expansion engine (read from the event-tap thread).
    public struct Matcher {
        public let maxLength: Int
        /// abbreviation (exact) -> snippet
        public let exact: [String: Snippet]
        /// lowercased abbreviation -> snippet, for case-insensitive snippets
        public let insensitive: [String: Snippet]

        /// 발화가 확정된 매치. 무엇을 몇 글자 지우고, 무엇을 다시 찍어야 하는지까지
        /// 담는다. 종결자가 필요한 약어는 종결자가 이미 타이핑된 뒤에야 발화하므로,
        /// 호출자가 약어 길이만 보고 백스페이스 수를 정하면 종결자가 남아 버린다.
        public struct Match {
            public let snippet: Snippet
            /// 지워야 할 글자 수. 약어 길이, 또는 약어 길이 + 종결자 길이.
            public let backspaces: Int
            /// 확장된 내용 뒤에 다시 찍어야 할 종결자. 구두점 시작 약어는 "".
            public let terminator: String

            public init(snippet: Snippet, backspaces: Int, terminator: String) {
                self.snippet = snippet
                self.backspaces = backspaces
                self.terminator = terminator
            }
        }

        /// 유니코드 기준 단어 문자. ASCII만 보면 한글·일본어·악센트 라틴이
        /// 전부 "경계"로 잘못 분류돼서, 단어 한가운데서 확장이 터진다.
        static func isWordCharacter(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        private func lookup(_ chars: [Character], _ range: Range<Int>) -> Snippet? {
            let key = String(chars[range])
            return exact[key] ?? insensitive[key.lowercased()]
        }

        /// 버퍼 끝에서 발화 조건을 만족하는 가장 긴 약어를 찾는다.
        ///
        /// 약어는 두 부류이고, 발화 조건이 서로 다르다.
        ///
        /// 1) 구두점으로 시작하는 약어(';sig', '/addr'): 접두 구두점이 스스로 경계라
        ///    접두 모호성이 없다. 버퍼가 약어로 끝나는 즉시 발화한다. 앞 글자가
        ///    무엇이든 상관없다 — 'a;sig'도 지금처럼 확장된다.
        ///
        /// 2) 단어 문자로 시작하는 맨몸 약어('sig', 'addr'): 이건 더 긴 단어의
        ///    접두사일 수 있다. 'sig' 스니펫을 둔 채 'signal'을 치면, s·i·g가 들어온
        ///    순간 "단어 머리에서 버퍼가 약어로 끝났다"가 성립하지만 사용자는 아직
        ///    단어를 다 치지 않았다. 여기서 발화하면 백스페이스와 n·a·l이 경합해
        ///    'SIGNATURE-BLOCKnal'이 된다. 그래서 종결자(단어 문자가 아닌 글자)가
        ///    실제로 타이핑될 때까지 기다린다. 버퍼가 <경계><약어><종결자>로 끝나야
        ///    비로소 발화하고, 이때 종결자는 이미 화면에 있으므로 함께 지웠다가
        ///    확장 내용 뒤에 다시 찍어준다.
        public func match(buffer: String) -> Match? {
            guard maxLength > 0, !buffer.isEmpty else { return nil }
            let chars = Array(buffer)
            let n = chars.count
            let upper = min(maxLength, n)

            // 최장 우선. 어떤 후보가 거부돼도 더 짧은 접미사가 여전히 정당할 수 있으므로
            // 스캔을 멈추지 않는다.
            for len in stride(from: upper, through: 1, by: -1) {

                // (1) 구두점 시작 약어 — 버퍼가 약어로 끝나면 즉시 발화.
                let start = n - len
                if let snippet = lookup(chars, start..<n),
                   !Self.isWordCharacter(chars[start]) {
                    return Match(snippet: snippet, backspaces: len, terminator: "")
                }

                // (2) 맨몸 약어 — <경계><약어><종결자> 로 끝나야 발화.
                //     마지막 글자가 방금 타이핑된 종결자다.
                let abbrevEnd = n - 1
                let abbrevStart = abbrevEnd - len
                if abbrevStart >= 0,
                   !Self.isWordCharacter(chars[abbrevEnd]),
                   let snippet = lookup(chars, abbrevStart..<abbrevEnd),
                   Self.isWordCharacter(chars[abbrevStart]),
                   // 약어 앞도 단어 경계여야 한다. 'desig ' 처럼 단어 안쪽에서
                   // 종결된 경우는 여전히 발화하면 안 된다.
                   abbrevStart == 0 || !Self.isWordCharacter(chars[abbrevStart - 1]) {
                    let terminator = String(chars[abbrevEnd])
                    return Match(
                        snippet: snippet,
                        backspaces: len + terminator.count,
                        terminator: terminator
                    )
                }
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

    /// 저장소 경로 해석의 **유일한** 지점. `Store()`를 만드는 곳이 두 곳이므로
    /// (`AppDelegate.swift`, `main.swift`의 헤드리스 `--import-te`), 여기서 갈라지면
    /// CLI 임포트가 사용자가 고른 위치가 아닌 엉뚱한 저장소로 들어간다.
    ///
    /// 우선순위에서 환경변수가 맨 위인 것은 **안전 요구사항**이다. 사용자가 동기화
    /// 위치를 골랐더라도 e2e 하네스가 그 라이브러리를 건드리면 안 된다.
    public static func resolveLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Location {
        // 테스트 격리용 오버라이드. 값이 비어 있으면 설정하지 않은 것으로 본다 —
        // 빈 문자열을 그대로 받아들이면 "/store.json"을 가리키게 된다.
        if let dir = environment[storeDirEnvKey], !dir.isEmpty {
            // 하네스 저장소는 비어 있는 게 정상이다. 사용 불가로 보면 e2e가
            // 첫 실행을 영영 못 한다.
            return Location(
                fileURL: URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent("store.json"),
                expectsExistingLibrary: false
            )
        }
        // 사용자가 직접 고른 위치. 여기에 파일이 없다는 것은 첫 실행이 아니라
        // "아직 못 받았다"이다.
        if let path = defaults.string(forKey: DeviceStateKey.storeLocationPath), !path.isEmpty {
            return Location(fileURL: URL(fileURLWithPath: path), expectsExistingLibrary: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Location(
            fileURL: base.appendingPathComponent("SnipKey/store.json"),
            expectsExistingLibrary: false
        )
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> URL {
        resolveLocation(environment: environment, defaults: defaults).fileURL
    }

    public convenience init() {
        self.init(location: Store.resolveLocation())
    }

    /// 경로를 직접 주는 경로 — 테스트와 하네스용. 포인터의 의미는 붙지 않으므로
    /// 파일이 없으면 지금까지처럼 첫 실행이다.
    public convenience init(fileURL: URL, deviceDefaults: UserDefaults = .standard) {
        self.init(
            location: Location(fileURL: fileURL, expectsExistingLibrary: false),
            deviceDefaults: deviceDefaults
        )
    }

    public init(location: Location, deviceDefaults: UserDefaults = .standard) {
        let fileURL = location.fileURL
        self.fileURL = fileURL
        self.expectsExistingLibrary = location.expectsExistingLibrary
        self.deviceDefaults = deviceDefaults

        var data = StoreData()
        var failure: LoadFailure?
        var blocked: SaveOutcome?
        var digest: FileDigest = .absent
        var unavailable = false
        var loadedFromDisk = false

        // A missing file is a first launch. A file that exists but will not read
        // or decode is something else entirely — possibly the user's whole
        // snippet library. Never treat that as "empty and ready to overwrite".
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let raw = try Data(contentsOf: fileURL)
                // 디코드보다 먼저 기록한다. 우리가 "아는" 상태는 해석 결과가 아니라
                // 읽은 바이트 그 자체다.
                digest = .sha(Self.sha256(of: raw))
                data = try JSONDecoder.snipKey.decode(StoreData.self, from: raw)
                loadedFromDisk = true
                if data.version > StoreData.currentVersion {
                    // 더 새로운 빌드의 Mac이 쓴 파일이다. 지금은 무해해 보이지만,
                    // 우리 스키마로 다시 쓰는 순간 우리가 모르는 필드가 조용히
                    // 사라진다. 동기화되는 파일에서 버전 검사가 없다는 것은 곧
                    // 구버전 앱이 신버전 파일을 다운그레이드하는 통로가 있다는 뜻이다.
                    blocked = .blockedByNewerSchema
                }
            } catch {
                let backup = Self.backUpUnreadableFile(at: fileURL)
                failure = LoadFailure(
                    message: error.localizedDescription,
                    originalURL: fileURL,
                    backupURL: backup
                )
                blocked = .blockedByLoadFailure
            }
        } else if location.expectsExistingLibrary {
            // 사용자가 이 위치를 명시적으로 골랐는데 파일이 없다. iCloud는 쓰지 않는
            // 파일을 자리표시자로 축출하므로, 그 순간 경로는 진짜로 존재하지 않는다.
            // 여기서 "첫 실행이니 빈 라이브러리"로 가면 그 빈 파일이 자리표시자를
            // 덮고, iCloud가 그 공백을 모든 Mac으로 전파한다. Mac 한 대, 실행 한 번,
            // 331개 소멸 — 동시성 같은 건 필요하지도 않다.
            unavailable = true
            blocked = .blockedByUnavailableLibrary
        }

        self.groups = data.groups
        self.macros = data.macros
        self.settings = data.settings
        self.loadFailure = failure
        self.isLibraryUnavailable = unavailable
        self.savesBlocked = blocked
        self.savedDigest = digest

        // 장치-로컬 상태 시드. 기존 사용자의 store.json에는 진짜 평생 확장 횟수가
        // 들어 있다. 업그레이드하면서 그걸 0으로 리셋하지 않는다.
        self.expansionCount = Self.seededInt(
            deviceDefaults,
            key: DeviceStateKey.expansionCount,
            seed: loadedFromDisk ? data.expansionCount : nil
        )
        self.didFinishOnboarding = Self.seededBool(
            deviceDefaults,
            key: DeviceStateKey.didFinishOnboarding,
            seed: loadedFromDisk ? data.settings.didFinishOnboarding : nil
        )
        rebuildIndex()
    }

    /// UserDefaults에 값이 **없을 때만** 파일 값으로 씨앗을 심는다. 이 분기가 없으면
    /// 매 실행마다 파일 값이 장치 값을 덮어써서, 장치-로컬로 뺀 의미가 사라진다.
    /// seed가 nil이면 (파일을 못 읽었거나 진짜 첫 실행이면) 아무것도 심지 않는다 —
    /// 나중에 파일이 도착했을 때 그때 시드할 수 있어야 하기 때문이다.
    private static func seededInt(_ defaults: UserDefaults, key: String, seed: Int?) -> Int {
        if let existing = defaults.object(forKey: key) as? Int { return existing }
        guard let seed else { return 0 }
        defaults.set(seed, forKey: key)
        return seed
    }

    private static func seededBool(_ defaults: UserDefaults, key: String, seed: Bool?) -> Bool {
        if let existing = defaults.object(forKey: key) as? Bool { return existing }
        guard let seed else { return false }
        defaults.set(seed, forKey: key)
        return seed
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 디스크의 현재 지문. 파일이 있는데 읽지 못하면 `.unreadable` — 그 상태를
    /// `.absent`로 뭉개면 "파일 없음"과 구별이 안 되고, 없다고 착각한 채 덮어쓴다.
    private static func currentDigest(at url: URL) -> FileDigest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let raw = try? Data(contentsOf: url) else { return .unreadable }
        return .sha(sha256(of: raw))
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
        // 사용자가 이 파일을 버리기로 명시적으로 골랐다. 쓰기 선결 조건은 "모르는
        // 사이에 바뀐 파일"을 막는 장치이지 이 결정을 막는 장치가 아니므로, 디스크의
        // 현재 상태를 그대로 "우리가 아는 상태"로 채택한다. 이게 없으면 읽지 못한
        // 파일의 지문을 영영 모르는 채로 남아 다음 저장이 원격 변경으로 오인된다.
        setLastKnownDigest(Self.currentDigest(at: fileURL))
        setBlockedReason(nil)
        groups = []
        macros = []
        saveNow()
    }

    /// Retries reading the file — for when the user has repaired or replaced it
    /// by hand. Returns true if the store loaded.
    @discardableResult
    public func retryLoadingStore() -> Bool {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.snipKey.decode(StoreData.self, from: raw),
              // 더 새로운 스키마라면 읽히는 것과 무관하게 여전히 만지면 안 된다.
              decoded.version <= StoreData.currentVersion
        else { return false }

        loadFailure = nil
        isLibraryUnavailable = false
        setLastKnownDigest(.sha(Self.sha256(of: raw)))
        setBlockedReason(nil)
        settings = decoded.settings
        macros = decoded.macros
        // expansionCount는 여기서 읽지 않는다 — 파일의 값은 다른 Mac의 숫자이고,
        // 이 Mac의 진짜 값은 UserDefaults에 있다.
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

    /// 확장 통계는 **장치-로컬**이다. 여기서 저장을 예약하면 안 된다.
    ///
    /// 예전에는 확장 한 번마다 scheduleSave()를 불렀다. 로컬 저장소에서는 그저
    /// 낭비였지만, 파일이 동기화되는 순간 그건 파괴 장치가 된다: 스니펫을 *쓰기만*
    /// 해도 파일이 더러워지므로, 사용자가 아무것도 편집하지 않은 Mac이 낡은
    /// 스냅샷으로 다른 Mac의 편집을 덮어쓴다. 게다가 쓰기 선결 조건(원격 변경 시
    /// 거부)이 있어도, 확장할 때마다 충돌 경고가 뜨는 앱은 못 쓸 물건이다.
    /// 파일은 사용자가 **진짜로 편집할 때만** 바뀌어야 한다.
    public func recordExpansion() {
        DispatchQueue.main.async {
            self.expansionCount += 1
            self.deviceDefaults.set(self.expansionCount, forKey: DeviceStateKey.expansionCount)
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
        if let reason = blockedReason { return reason }
        let data = snapshotFromAnyThread()
        saveWorkItem?.cancel()
        return saveQueue.sync { write(data) }
    }

    private func write(_ data: StoreData) -> SaveOutcome {
        if let reason = blockedReason { return reason }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = try JSONEncoder.snipKey.encode(data)

            var outcome: SaveOutcome = .saved
            var writeError: Error?
            var coordinationError: NSError?

            // 검사와 쓰기가 **한 조율 블록 안에** 있어야 한다. 검사만 하고 블록 밖에서
            // 쓰면 그 사이에 iCloud 데몬이 파일을 실체화해 검사가 무의미해진다.
            // (블록 안이어도 다른 Mac에 대해서는 TOCTOU 창이 남는다 — 그걸 완전히
            //  닫으려면 크로스-머신 락, 즉 동기화 엔진이 필요하고 그건 범위 밖이다.
            //  여기서 막는 것은 "몇 초 전에 전파돼 온 변경"이라는 현실의 경우다.)
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: fileURL, options: [], error: &coordinationError
            ) { url in
                let onDisk = Self.currentDigest(at: url)
                guard onDisk == self.lastKnownDigest else {
                    // 마지막으로 읽은 그 파일이 아니다. 다른 Mac이 편집했고, 우리
                    // 스냅샷은 이미 낡았다. 마지막 쓰기 승리는 곧 이 SPEC이 고치려는
                    // 버그 그 자체이므로, 승자를 고르지 않고 사용자에게 넘긴다.
                    // 인메모리 라이브러리는 손대지 않는다 — 양쪽 다 살아 있어야 한다.
                    outcome = .blockedByRemoteChange
                    return
                }
                do {
                    try raw.write(to: url, options: .atomic)
                    // 우리 자신의 쓰기를 다음번에 원격 변경으로 오해하지 않도록.
                    self.setLastKnownDigest(.sha(Self.sha256(of: raw)))
                } catch {
                    writeError = error
                }
            }

            if let coordinationError { return .failed(coordinationError.localizedDescription) }
            if let writeError { throw writeError }
            if outcome == .blockedByRemoteChange { setBlockedReason(.blockedByRemoteChange) }
            return outcome
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
