import Foundation

/// 저장소 파일의 외부 변경을 알리는 감시자. 프로토콜로 두는 이유는 두 가지다:
/// 테스트가 변경 알림을 결정적으로 흘려보낼 수 있어야 하고(REQ-DET-005), 헤드리스·CLI
/// 경로는 감시자 없이 돌아야 하기 때문이다(주입해서 nil로 끌 수 있게).
///
/// 안전은 이 감시자에 **의존하지 않는다**(REQ-DET-004). 감시자가 한 번도 안 울려도
/// 쓰기 선결 조건만으로 데이터는 지켜진다. 감시자는 신속한 리로드를 위한 편의다.
public protocol StoreWatching: AnyObject {
    /// 감시 대상 디렉터리에서 변경이 감지되면 호출된다. 임의 스레드에서 불릴 수 있다.
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// 저장소 파일이 든 **디렉터리**를 감시한다. 파일 자체의 fd를 감시하면 안 되는데,
/// `.atomic` 쓰기(`Store.write`)와 iCloud 실체화가 매번 파일의 inode를 교체하기
/// 때문이다 — fd에 건 `DispatchSource`는 첫 쓰기 이후 이미 사라진 inode를 가리키는
/// 좀비가 되어 조용히 죽는다. "돌아가는 것처럼 보이지만 첫 변경 뒤로는 아무것도 못
/// 보는" 감시자가 특히 위험하다. 디렉터리 inode는 안정적이므로, 디렉터리에 이벤트가
/// 뜰 때마다 대상 파일을 다시 확인하면 된다. (회귀 방어: AC-CORE-008)
public final class DirectoryWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "snipkey.store.watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func start() {
        stop()
        // 아직 없는 디렉터리는 열 수 없다. 저장소를 처음 만드는 첫 실행에서도
        // 감시가 서 있으려면 여기서 디렉터리를 확보해 둔다.
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.onChange?() }
        src.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
