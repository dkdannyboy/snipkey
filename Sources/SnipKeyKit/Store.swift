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

    /// 다른 Mac이 파일을 바꿔서 저장이 막힌 상태. 백그라운드 디바운스 저장이 막히면
    /// 그 결과가 버려지므로(`scheduleSave`는 outcome을 무시한다), 이 published 상태로
    /// UI에 표면화해야 사용자가 해소 경로를 볼 수 있다 (REQ-WRITE-004).
    public struct RemoteChange: Equatable {
        public let detectedAt: Date
        public init(detectedAt: Date) { self.detectedAt = detectedAt }
    }

    /// 원격 변경을 해소한 결과. 어느 옵션이든 양쪽 버전이 디스크에 남게 만든다.
    public struct ConflictResolution: Equatable {
        /// 회수 가능하도록 남긴 백업/형제 파일의 경로.
        public let backupURL: URL?
        public let outcome: SaveOutcome
    }

    /// 위치 전환의 결과. 백업 경로를 담아 사용자에게 어디에 무엇이 보존됐는지 알린다.
    public struct RelocationResult: Equatable {
        public let success: Bool
        public let backupURL: URL?
        public let message: String?
        public let activeLocation: URL
    }

    /// iCloud가 만든 미해결 충돌 복사본 하나. 앱은 이것을 **보여주기만** 한다 —
    /// 승자를 고르지 않는다 (REQ-CONF-002).
    public struct ConflictVersion: Equatable, Identifiable {
        public let id: URL
        public let url: URL
        public let modificationDate: Date?
        public init(url: URL, modificationDate: Date?) {
            self.id = url
            self.url = url
            self.modificationDate = modificationDate
        }
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
    /// 원격 변경으로 저장이 막혔다. UI가 이걸 관찰해 해소 옵션을 띄운다.
    @Published public private(set) var remoteChange: RemoteChange?

    /// 현재 활성 저장소 위치. 재배치되므로 `let`일 수 없다 (REQ-LOC-006).
    private var fileURL: URL
    /// 파일 부재를 첫 실행으로 볼 것인가, 사용 불가로 볼 것인가.
    private var expectsExistingLibrary: Bool
    private let deviceDefaults: UserDefaults
    /// 로컬 기본 위치(`~/Library/Application Support/SnipKey`). "Don't Sync"의 목적지이자
    /// 백업이 쌓이는 곳이다. 동기화되지 않는 로컬이어야 백업까지 클라우드로 새 나가지
    /// 않는다. 테스트가 실제 홈 디렉터리를 더럽히지 않도록 주입 가능하게 둔다.
    private let localSupportDirectory: URL
    private var localDefaultURL: URL { localSupportDirectory.appendingPathComponent("store.json") }
    private var backupDirectory: URL { localSupportDirectory }

    /// 감시자를 경로별로 새로 만드는 팩토리. 인스턴스가 아니라 팩토리인 것은 재배치
    /// 때문이다 — 위치가 바뀌면 새 디렉터리를 감시하는 새 감시자가 필요하다.
    /// 테스트는 nil을 돌려주는 기본 팩토리로 감시자를 끄고, 필요한 테스트만 주입한다.
    private let watcherFactory: (URL) -> StoreWatching?
    private var watcher: StoreWatching?

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "snipkey.store.save")
    /// 디스크 상태를 채택하는 중(리로드·재배치)에는 저장을 걸지 않는다. 채택은 곧
    /// 디스크와 같아지는 것이므로 되받아쓰기가 무의미할 뿐 아니라, 확장 횟수 차이로
    /// 두 Mac이 서로의 리로드를 유발하는 핑퐁 쓰기 폭풍이 된다. (메인 스레드 전용)
    private var isApplyingExternalState = false
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

    /// 마지막으로 디스크와 맞춰진 **내용**의 지문 — 확장 횟수를 뺀 것. 이 값과
    /// 현재 인메모리 내용을 비교해 "사용자가 실제로 편집했는가(dirty)"를 판정한다.
    /// 파일 전체 지문(`savedDigest`)과 다른 이유는 하나다: 확장 횟수는 장치-로컬이라
    /// 파일에는 들어가지만 편집이 아니다. 그걸 dirty 판정에 섞으면 확장만 해도
    /// 원격 변경이 충돌로 오인된다 (AC-DIRTY-001의 거짓 양성).
    private let contentDigestLock = NSLock()
    private var _lastKnownContentDigest: String = ""
    private var lastKnownContentDigest: String {
        contentDigestLock.lock()
        defer { contentDigestLock.unlock() }
        return _lastKnownContentDigest
    }
    private func setLastKnownContentDigest(_ digest: String) {
        contentDigestLock.lock()
        _lastKnownContentDigest = digest
        contentDigestLock.unlock()
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

    /// "Save Snippets As…"가 동기화 폴더에 만드는 파일 이름. 기본 로컬 저장소의
    /// `store.json`과 이름을 달리해, 같은 폴더를 골라도 로컬 파일과 헷갈리지 않는다.
    public static let syncedFileName = "SnipKey-snippets.json"

    /// 로컬 기본 지원 디렉터리(`~/Library/Application Support/SnipKey`).
    public static var defaultLocalSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnipKey", isDirectory: true)
    }

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
        // 앱 경로. 해석된 위치의 디렉터리를 감시하는 실제 감시자를 붙인다.
        self.init(
            location: Store.resolveLocation(),
            watcherFactory: { DirectoryWatcher(directoryURL: $0) }
        )
    }

    /// 경로를 직접 주는 경로 — 테스트와 하네스용. 포인터의 의미는 붙지 않으므로
    /// 파일이 없으면 지금까지처럼 첫 실행이다. 감시자는 붙지 않는다.
    public convenience init(fileURL: URL, deviceDefaults: UserDefaults = .standard) {
        self.init(
            location: Location(fileURL: fileURL, expectsExistingLibrary: false),
            deviceDefaults: deviceDefaults
        )
    }

    public init(
        location: Location,
        deviceDefaults: UserDefaults = .standard,
        localSupportDirectory: URL = Store.defaultLocalSupportDirectory,
        watcherFactory: @escaping (URL) -> StoreWatching? = { _ in nil }
    ) {
        let fileURL = location.fileURL
        self.fileURL = fileURL
        self.expectsExistingLibrary = location.expectsExistingLibrary
        self.deviceDefaults = deviceDefaults
        self.localSupportDirectory = localSupportDirectory
        self.watcherFactory = watcherFactory

        let loaded = Self.loadFrom(location)
        self.groups = loaded.groups
        self.macros = loaded.macros
        self.settings = loaded.settings
        self.loadFailure = loaded.loadFailure
        self.isLibraryUnavailable = loaded.unavailable
        self.remoteChange = nil
        self.savesBlocked = loaded.blocked
        self.savedDigest = loaded.digest
        self._lastKnownContentDigest = loaded.contentDigest

        // 장치-로컬 상태 시드. 기존 사용자의 store.json에는 진짜 평생 확장 횟수가
        // 들어 있다. 업그레이드하면서 그걸 0으로 리셋하지 않는다.
        self.expansionCount = Self.seededInt(
            deviceDefaults,
            key: DeviceStateKey.expansionCount,
            seed: loaded.fileExpansionCount
        )
        self.didFinishOnboarding = Self.seededBool(
            deviceDefaults,
            key: DeviceStateKey.didFinishOnboarding,
            seed: loaded.fileDidFinishOnboarding
        )
        rebuildIndex()

        self.watcher = watcherFactory(fileURL.deletingLastPathComponent())
        startWatching()
    }

    deinit { watcher?.stop() }

    /// 로드 결과 꾸러미. init은 저장 프로퍼티를 직접 채워야 하고(초기화 전에는 메서드로
    /// @Published를 못 만진다), 재배치는 메서드로 채운다. 두 경로가 같은 로직을 쓰도록
    /// 여기 한 곳에서 계산한다.
    private struct Loaded {
        var groups: [SnippetGroup] = []
        var macros: [HotkeyMacro] = []
        var settings: AppSettings = AppSettings()
        var digest: FileDigest = .absent
        var contentDigest: String = ""
        var loadFailure: LoadFailure?
        var unavailable = false
        var blocked: SaveOutcome?
        var fileExpansionCount: Int?
        var fileDidFinishOnboarding: Bool?
    }

    private static func loadFrom(_ location: Location) -> Loaded {
        let fileURL = location.fileURL
        var out = Loaded()
        let emptyContentDigest = contentDigest(groups: [], macros: [], settings: AppSettings())

        // A missing file is a first launch. A file that exists but will not read
        // or decode is something else entirely — possibly the user's whole
        // snippet library. Never treat that as "empty and ready to overwrite".
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                // 조율된 읽기. 실체화 중인 iCloud 파일을 반쯤 쓰인 채로 읽지 않도록
                // NSFileCoordinator 안에서 읽는다 (REQ-CLOUD-003).
                let raw = try coordinatedRead(fileURL)
                // 디코드보다 먼저 기록한다. 우리가 "아는" 상태는 해석 결과가 아니라
                // 읽은 바이트 그 자체다.
                out.digest = .sha(sha256(of: raw))
                let data = try JSONDecoder.snipKey.decode(StoreData.self, from: raw)
                out.groups = data.groups
                out.macros = data.macros
                out.settings = data.settings
                out.contentDigest = contentDigest(groups: data.groups, macros: data.macros, settings: data.settings)
                out.fileExpansionCount = data.expansionCount
                out.fileDidFinishOnboarding = data.settings.didFinishOnboarding
                if data.version > StoreData.currentVersion {
                    // 더 새로운 빌드의 Mac이 쓴 파일이다. 지금은 무해해 보이지만,
                    // 우리 스키마로 다시 쓰는 순간 우리가 모르는 필드가 조용히
                    // 사라진다. 동기화되는 파일에서 버전 검사가 없다는 것은 곧
                    // 구버전 앱이 신버전 파일을 다운그레이드하는 통로가 있다는 뜻이다.
                    out.blocked = .blockedByNewerSchema
                }
            } catch {
                // 읽거나 디코드하지 못했다. 그러나 이것이 손상이 아니라 아직 안
                // 내려받은 iCloud 자리표시자일 수 있다 — 그 경우는 loadFailure가
                // 아니라 unavailable이고, 다운로드를 걸어 두면 실체화됐을 때 살아난다.
                if location.expectsExistingLibrary, requestDownloadIfPlaceholder(at: fileURL) {
                    out.unavailable = true
                    out.blocked = .blockedByUnavailableLibrary
                    out.contentDigest = emptyContentDigest
                    out.digest = out.digest == .absent ? .unreadable : out.digest
                } else {
                    let backup = backUpUnreadableFile(at: fileURL)
                    out.loadFailure = LoadFailure(
                        message: error.localizedDescription,
                        originalURL: fileURL,
                        backupURL: backup
                    )
                    out.blocked = .blockedByLoadFailure
                    out.contentDigest = emptyContentDigest
                }
            }
        } else if location.expectsExistingLibrary {
            // 사용자가 이 위치를 명시적으로 골랐는데 파일이 없다. iCloud는 쓰지 않는
            // 파일을 자리표시자로 축출하므로, 그 순간 경로는 진짜로 존재하지 않는다.
            // 여기서 "첫 실행이니 빈 라이브러리"로 가면 그 빈 파일이 자리표시자를
            // 덮고, iCloud가 그 공백을 모든 Mac으로 전파한다. Mac 한 대, 실행 한 번,
            // 331개 소멸 — 동시성 같은 건 필요하지도 않다.
            _ = requestDownloadIfPlaceholder(at: fileURL)
            out.unavailable = true
            out.blocked = .blockedByUnavailableLibrary
            out.contentDigest = emptyContentDigest
        } else {
            // 첫 실행. 빈 라이브러리로 시작하고 저장을 허용한다.
            out.contentDigest = emptyContentDigest
        }
        return out
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

    /// 확장 횟수를 뺀 "내용"만의 지문. 확장은 장치-로컬이라 편집이 아니므로 dirty
    /// 판정에 섞이면 안 된다 — 섞이면 확장만 해도 원격 변경이 충돌로 오인된다.
    private static func contentDigest(
        groups: [SnippetGroup], macros: [HotkeyMacro], settings: AppSettings
    ) -> String {
        let probe = StoreData(
            version: StoreData.currentVersion,
            groups: groups, macros: macros, settings: settings,
            expansionCount: 0
        )
        let raw = (try? JSONEncoder.snipKey.encode(probe)) ?? Data()
        return sha256(of: raw)
    }

    /// 조율된 읽기. iCloud 데몬이 실체화 중인 파일을 반쯤 쓰인 채로 읽지 않도록
    /// NSFileCoordinator 읽기 조율 안에서 읽는다 (REQ-CLOUD-003). 쓰기 조율 블록
    /// **안에서는** 부르지 않는다 — 같은 스레드의 중첩 조율은 교착의 소지가 있다.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var readData: Data?
        var readError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { u in
            do { readData = try Data(contentsOf: u) } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let readData else { throw CocoaError(.fileReadUnknown) }
        return readData
    }

    /// iCloud 자리표시자(아직 안 내려받은 유비쿼티 항목)면 다운로드를 걸고 true를
    /// 돌려준다. 실제 iCloud 동작은 CI에서 검증 불가 — 수동 체크리스트(M-05)로 남는다.
    @discardableResult
    private static func requestDownloadIfPlaceholder(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true
        else { return false }
        if values.ubiquitousItemDownloadingStatus == .current { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
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
        setLastKnownContentDigest(Self.contentDigest(groups: [], macros: [], settings: settings))
        setBlockedReason(nil)
        groups = []
        macros = []
        saveNow()
    }

    /// Retries reading the file — for when the user has repaired or replaced it
    /// by hand. Returns true if the store loaded.
    @discardableResult
    public func retryLoadingStore() -> Bool {
        guard let raw = try? Self.coordinatedRead(fileURL),
              let decoded = try? JSONDecoder.snipKey.decode(StoreData.self, from: raw),
              // 더 새로운 스키마라면 읽히는 것과 무관하게 여전히 만지면 안 된다.
              decoded.version <= StoreData.currentVersion
        else { return false }

        loadFailure = nil
        isLibraryUnavailable = false
        remoteChange = nil
        setLastKnownDigest(.sha(Self.sha256(of: raw)))
        setLastKnownContentDigest(Self.contentDigest(groups: decoded.groups, macros: decoded.macros, settings: decoded.settings))
        setBlockedReason(nil)
        settings = decoded.settings
        macros = decoded.macros
        // expansionCount는 여기서 읽지 않는다 — 파일의 값은 다른 Mac의 숫자이고,
        // 이 Mac의 진짜 값은 UserDefaults에 있다.
        groups = decoded.groups // last: its didSet rebuilds the matcher and saves
        return true
    }

    // MARK: - External change detection (M3)

    private func startWatching() {
        guard let watcher else { return }
        watcher.onChange = { [weak self] in
            // 감시자는 임의 스레드에서 부른다. 결정 로직은 @Published를 만지므로 메인으로.
            DispatchQueue.main.async { self?.externalChangeDetected() }
        }
        watcher.start()
    }

    /// 감시자가 디렉터리 변경을 알릴 때 부르는 결정 지점. 감시자는 얇게 두고 무엇을
    /// 할지는 여기서 정한다 — 그래야 벽시계 없이 테스트가 이 로직을 동기적으로 부를 수
    /// 있다. (메인 스레드에서. 감시자 배선이 main으로 hop하고 테스트도 main에서 부른다.)
    public func externalChangeDetected() {
        // 읽지 못한 파일은 기존 복구 UI가 우선한다. 자동으로 손대지 않는다 (AC-SIDE-007 정신).
        guard loadFailure == nil else { return }
        let onDisk = Self.currentDigest(at: fileURL)
        // 우리가 아는 그 파일 그대로. 우리 자신의 쓰기이거나 무관한 디렉터리 이벤트다.
        guard onDisk != lastKnownDigest else { return }
        if hasUnsavedChanges() {
            // 미저장 로컬 편집이 있다. 리로드하면 그 편집이 사라진다 — 원래 버그의
            // 거울상. 리로드하지 않고, 저장을 막아 쓰기 선결 조건과 같은 결말로
            // 사용자에게 넘긴다. 인메모리 라이브러리는 손대지 않는다 (AC-DIRTY-001).
            setBlockedReason(.blockedByRemoteChange)
            publishRemoteChange()
        } else {
            // 깨끗하다. 조용히 디스크 내용을 채택한다 (저장 유발 없이).
            reloadFromDisk(force: false)
        }
    }

    /// 사용자가 실제로 편집했으나 아직 디스크에 반영되지 않았는가. 확장 횟수는 제외한다
    /// — 확장은 편집이 아니다. 메인 스레드에서만 부른다(@Published를 읽는다).
    private func hasUnsavedChanges() -> Bool {
        Self.contentDigest(groups: groups, macros: macros, settings: settings) != lastKnownContentDigest
    }

    /// 디스크의 현재 내용을 채택한다. **저장을 유발하지 않는다**(핑퐁 방지) —
    /// `isApplyingExternalState`로 didSet의 scheduleSave를 억제한다.
    /// force=false면 미저장 로컬 편집이 있을 때 채택을 거부한다(REQ-DET-003).
    @discardableResult
    private func reloadFromDisk(force: Bool) -> Bool {
        if !force && hasUnsavedChanges() { return false }
        let loaded = Self.loadFrom(Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary))
        // 더 새로운 스키마면 채택하지 않고 차단만 갱신한다.
        if loaded.blocked == .blockedByNewerSchema {
            setLastKnownDigest(loaded.digest)
            setBlockedReason(.blockedByNewerSchema)
            return false
        }
        // 로드 실패면 채택하지 않는다 — 기존 복구 UI가 처리한다.
        if loaded.loadFailure != nil { return false }
        applyLoaded(loaded)
        return true
    }

    /// 로드 결과를 @Published 상태에 반영한다. 저장은 억제한다. init이 아니라
    /// 재배치·리로드에서 쓴다. 확장 횟수(장치-로컬)는 손대지 않는다.
    private func applyLoaded(_ loaded: Loaded) {
        isApplyingExternalState = true
        defer { isApplyingExternalState = false }
        setLastKnownDigest(loaded.digest)
        setLastKnownContentDigest(loaded.contentDigest)
        setBlockedReason(loaded.blocked)
        loadFailure = loaded.loadFailure
        isLibraryUnavailable = loaded.unavailable
        remoteChange = nil
        settings = loaded.settings
        macros = loaded.macros
        groups = loaded.groups // 마지막: didSet이 matcher를 다시 세운다 (저장은 억제됨)
    }

    private func publishRemoteChange() {
        let update = { self.remoteChange = RemoteChange(detectedAt: Date()) }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private func clearRemoteChange() {
        if Thread.isMainThread { remoteChange = nil }
        else { DispatchQueue.main.async { self.remoteChange = nil } }
    }

    // MARK: - Remote-change resolution (REQ-WRITE-005)
    //
    // 세 옵션 모두 **양쪽 버전을 디스크에 남긴다.** 마지막 쓰기 승리(한쪽 소멸)는
    // 이 SPEC이 고치려는 버그 그 자체이므로 어디에도 없다.

    /// (a) 그쪽 것을 취한다. 로컬 편집을 백업으로 내보내고, 디스크의 것을 채택한다.
    @discardableResult
    public func resolveByTakingRemote() -> ConflictResolution {
        let backup = exportCurrentLibrary(tag: "local-edits")
        setBlockedReason(nil)
        reloadFromDisk(force: true)
        clearRemoteChange()
        return ConflictResolution(backupURL: backup, outcome: .saved)
    }

    /// (b) 내 것을 지킨다. 그쪽(디스크) 것을 먼저 백업하고, 내 것을 강제로 쓴다.
    @discardableResult
    public func resolveByKeepingLocal() -> ConflictResolution {
        let backup = backUpOnDiskFile(tag: "remote-version")
        let outcome = forceWriteCurrent()
        clearRemoteChange()
        return ConflictResolution(backupURL: backup, outcome: outcome)
    }

    /// (c) 둘 다 지킨다. 내 것을 형제 파일로 쓰고, 그쪽 것을 리로드한다.
    @discardableResult
    public func resolveByKeepingBoth() -> ConflictResolution {
        let sibling = writeCurrentToSibling()
        setBlockedReason(nil)
        reloadFromDisk(force: true)
        clearRemoteChange()
        return ConflictResolution(backupURL: sibling, outcome: .saved)
    }

    private func forceWriteCurrent() -> SaveOutcome {
        setBlockedReason(nil)
        let data = snapshotFromAnyThread()
        saveWorkItem?.cancel()
        return saveQueue.sync { write(data, force: true) }
    }

    /// 디스크의 현재 파일(theirs)을 타임스탬프 백업으로 복사한다.
    private func backUpOnDiskFile(tag: String) -> URL? {
        guard let raw = try? Self.coordinatedRead(fileURL) else { return nil }
        return Self.writeBackup(raw, into: backupDirectory, tag: tag)
    }

    /// 내 것을 대상 파일 옆 형제 파일로 쓴다. 대상은 건드리지 않는다.
    private func writeCurrentToSibling() -> URL? {
        let snap = snapshotFromAnyThread()
        guard let raw = try? JSONEncoder.snipKey.encode(snap) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let sibling = fileURL.deletingLastPathComponent()
            .appendingPathComponent("SnipKey-mine-\(f.string(from: Date())).json")
        do { try raw.write(to: sibling); return sibling } catch { return nil }
    }

    // MARK: - Conflict copies (REQ-CONF)

    /// iCloud가 만든 미해결 충돌 버전들을 **보여주기만** 한다. 승자를 고르지도,
    /// 해결됨으로 표시하지도, 자동 병합하지도 않는다 (REQ-CONF-002).
    public func unresolvedConflicts() -> [ConflictVersion] {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) else { return [] }
        return versions.map { ConflictVersion(url: $0.url, modificationDate: $0.modificationDate) }
    }

    /// 충돌 버전의 내용을 기존 임포트 경로로 불러온다 — 새 병합 UI를 만들지 않는다
    /// (REQ-CONF-003).
    @discardableResult
    public func importConflictVersion(at url: URL) -> SaveOutcome {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.snipKey.decode(StoreData.self, from: raw)
        else { return .failed("충돌 버전을 읽을 수 없습니다.") }
        return importGroups(decoded.groups)
    }

    // MARK: - Store location switching (M4)

    /// 현재 활성 저장소 위치. Settings의 경로 표시(REQ-LOC-007)에 쓴다.
    public var activeLocationURL: URL { fileURL }
    /// 사용자가 명시적으로 고른 동기화 위치를 쓰고 있는가 (포인터 설정됨).
    public var isUsingConfiguredLocation: Bool { expectsExistingLibrary }

    /// REQ-LOC-003. 현재 라이브러리 사본을 고른 폴더에 쓰고, 포인터를 그리로 돌린다.
    /// 기존 로컬 파일은 손대지 않는다 (REQ-LOC-008). 대상 폴더에 이미 파일이 있으면
    /// 먼저 백업한다 — 남의 파일을 말없이 덮지 않는다.
    @discardableResult
    public func saveSnippetsAs(toDirectory directory: URL) -> RelocationResult {
        let target = directory.appendingPathComponent(Self.syncedFileName)
        var backup: URL?
        if FileManager.default.fileExists(atPath: target.path),
           let existing = try? Self.coordinatedRead(target), !existing.isEmpty {
            backup = Self.writeBackup(existing, into: backupDirectory, tag: "pre-save-as")
        }
        let snap = snapshotFromAnyThread()
        guard let raw = try? JSONEncoder.snipKey.encode(snap) else {
            return RelocationResult(success: false, backupURL: backup,
                                    message: "라이브러리를 인코딩하지 못했습니다.", activeLocation: fileURL)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raw.write(to: target, options: .atomic)
        } catch {
            return RelocationResult(success: false, backupURL: backup,
                                    message: error.localizedDescription, activeLocation: fileURL)
        }
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        relocate(to: Location(fileURL: target, expectsExistingLibrary: true))
        return RelocationResult(success: true, backupURL: backup, message: nil, activeLocation: fileURL)
    }

    /// REQ-LOC-004. 기존 동기화 파일을 가리킨다. 먼저 로컬 라이브러리를 타임스탬프
    /// 백업으로 내보내고(회수 가능하게), 대상 파일은 **절대 덮지 않으며**, 대상의
    /// 내용을 채택한다. 그리고 온보딩 완료 플래그를 지운다 — 두 번째 Mac에서 온보딩이
    /// 다시 떠야 하는데, 파일의 didFinishOnboarding:true가 빈 UserDefaults를 시드하면
    /// 잘못 억제되기 때문이다 (M1/M2 보고서가 M4 의무로 명시한 항목).
    @discardableResult
    public func linkToSnippets(at target: URL) -> RelocationResult {
        // 로컬 5개를 먼저 백업한다. relocate가 대상(331개)을 채택하면 인메모리가
        // 교체되므로, 백업은 반드시 그 전에 떠야 한다.
        let localBackup = exportCurrentLibrary(tag: "local-before-link")
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        // 온보딩 플래그를 명시적으로 내린다. 이 값이 UserDefaults에 존재하면 다음
        // 실행의 시드 분기가 파일 값(true)으로 덮어쓰지 않아, 온보딩이 다시 뜬다.
        didFinishOnboarding = false
        // relocate는 대상을 **채택만** 한다(우리 것을 쓰지 않는다). 대기 중 저장을
        // 버리므로 로컬 5개가 331개 위에 실릴 위험도 없다.
        relocate(to: Location(fileURL: target, expectsExistingLibrary: true))
        let message = localBackup.map { "이전 로컬 스니펫을 \($0.lastPathComponent)에 백업했습니다." }
        return RelocationResult(success: true, backupURL: localBackup, message: message, activeLocation: fileURL)
    }

    /// REQ-LOC-005. 로컬 기본 경로로 돌아간다. 현재 라이브러리를 로컬 기본에 복사하고
    /// 포인터를 지운다. 동기화 파일은 그대로 둔다 (REQ-LOC-008).
    @discardableResult
    public func stopSyncing() -> RelocationResult {
        var backup: URL?
        if FileManager.default.fileExists(atPath: localDefaultURL.path),
           let existing = try? Self.coordinatedRead(localDefaultURL), !existing.isEmpty {
            backup = Self.writeBackup(existing, into: backupDirectory, tag: "pre-stop-sync")
        }
        let snap = snapshotFromAnyThread()
        if let raw = try? JSONEncoder.snipKey.encode(snap) {
            try? FileManager.default.createDirectory(
                at: localDefaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? raw.write(to: localDefaultURL, options: .atomic)
        }
        deviceDefaults.removeObject(forKey: DeviceStateKey.storeLocationPath)
        relocate(to: Location(fileURL: localDefaultURL, expectsExistingLibrary: false))
        return RelocationResult(success: true, backupURL: backup, message: nil, activeLocation: fileURL)
    }

    /// REQ-LOC-006. 실행 중 위치 변경. Store를 새로 만들지 않고 **제자리에서** 재배치한다
    /// — AppDelegate가 이 Store를 engine/hotkeys/statusBar에 이미 주입했기 때문이다
    /// (`AppDelegate.swift:17-25`). 대기 중 저장을 결정적으로 처리하고, 새 파일을 다시
    /// 읽고, matcher를 재구축하며, 감시자를 새 디렉터리로 재무장한다. 앱 재시작 불필요.
    public func relocate(to location: Location) {
        // 대기 중 디바운스 저장을 결정적으로 버린다. 현재 상태는 이동 전에 대상에
        // 이미 반영됐거나(Save As/Don't Sync) 대상을 채택할 것이므로(Link), 옛 경로로의
        // 지연 저장은 무의미하고, Link에서는 그 저장이 남의 파일을 덮을 위험이다.
        saveWorkItem?.cancel()
        saveWorkItem = nil
        watcher?.stop()

        fileURL = location.fileURL
        expectsExistingLibrary = location.expectsExistingLibrary

        let loaded = Self.loadFrom(location)
        applyLoaded(loaded) // matcher 재구축 포함, 저장 유발 억제

        watcher = watcherFactory(fileURL.deletingLastPathComponent())
        startWatching()
    }

    /// 현재 인메모리 라이브러리를 백업 디렉터리(로컬, 동기화 안 됨)에 타임스탬프
    /// 파일로 내보낸다.
    private func exportCurrentLibrary(tag: String) -> URL? {
        let snap = snapshotFromAnyThread()
        guard let raw = try? JSONEncoder.snipKey.encode(snap) else { return nil }
        return Self.writeBackup(raw, into: backupDirectory, tag: tag)
    }

    private static func writeBackup(_ raw: Data, into directory: URL, tag: String) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = directory.appendingPathComponent("snipkey-backup-\(tag)-\(f.string(from: Date())).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raw.write(to: url)
            return url
        } catch { return nil }
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
        // 저장이 막혔거나, 디스크 상태를 채택하는 중이면 예약하지 않는다. 후자는
        // 리로드·재배치 중 되받아쓰기를 막아 두 Mac 사이 핑퐁 쓰기를 차단한다.
        guard !isSavingBlocked, !isApplyingExternalState else { return }
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

    private func write(_ data: StoreData, force: Bool = false) -> SaveOutcome {
        if !force, let reason = blockedReason { return reason }
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
                if !force {
                    let onDisk = Self.currentDigest(at: url)
                    guard onDisk == self.lastKnownDigest else {
                        // 마지막으로 읽은 그 파일이 아니다. 다른 Mac이 편집했고, 우리
                        // 스냅샷은 이미 낡았다. 마지막 쓰기 승리는 곧 이 SPEC이 고치려는
                        // 버그 그 자체이므로, 승자를 고르지 않고 사용자에게 넘긴다.
                        // 인메모리 라이브러리는 손대지 않는다 — 양쪽 다 살아 있어야 한다.
                        outcome = .blockedByRemoteChange
                        return
                    }
                }
                do {
                    try raw.write(to: url, options: .atomic)
                    // 우리 자신의 쓰기를 다음번에 원격 변경으로 오해하지 않도록.
                    self.setLastKnownDigest(.sha(Self.sha256(of: raw)))
                    self.setLastKnownContentDigest(
                        Self.contentDigest(groups: data.groups, macros: data.macros, settings: data.settings))
                } catch {
                    writeError = error
                }
            }

            if let coordinationError { return .failed(coordinationError.localizedDescription) }
            if let writeError { throw writeError }
            if outcome == .blockedByRemoteChange {
                setBlockedReason(.blockedByRemoteChange)
                // 백그라운드 디바운스 저장이 여기서 막히면 outcome이 버려지므로,
                // published 상태로 UI에 표면화한다 (REQ-WRITE-004).
                publishRemoteChange()
            }
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
