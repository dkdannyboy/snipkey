import Foundation

/// iCloud(유비쿼티) 저장소 파일의 **원격** 변경을 감지하는 감시자.
///
/// `DirectoryWatcher`(DispatchSource/kqueue vnode)는 이 Mac에서 일어나는 **로컬** 쓰기는
/// 확실히 잡지만, 다른 Mac에서 만든 변경을 iCloud 데몬이 내려받아 파일에 반영할 때는
/// vnode 이벤트가 신뢰성 있게 뜨지 않는다. 그래서 "저장했는데 다른 Mac에는 재시작 전까지
/// 안 뜬다"는 버그가 생긴다. Apple이 바로 그 목적(유비쿼티 항목 변경 관찰)에 두라고 만든
/// API가 `NSMetadataQuery`다 (또는 등록된 `NSFilePresenter`).
///
/// 이 감시자는 유비쿼티 스코프에서 대상 파일을 질의하고 `.NSMetadataQueryDidUpdate`와
/// `.NSMetadataQueryDidFinishGathering` 알림을 `onChange`로 변환한다. **결정 로직은 갖지
/// 않는다** — `DirectoryWatcher`와 똑같이 "무언가 바뀌었다"만 알리고, 무엇을 할지는
/// `Store.externalChangeDetected()`가 지문 비교로 정한다. 따라서 중복 발화(로컬 감시자와
/// 원격 감시자가 같은 변경에 둘 다 우는 경우)는 무해하다.
///
/// 안전은 이 감시자에 **의존하지 않는다**(REQ-DET-004). 한 번도 안 울려도 쓰기 선결
/// 조건이 데이터를 지킨다. 감시자는 신속한 리로드를 위한 편의다.
// @MX:NOTE: [AUTO] iCloud 원격 반영은 kqueue로 안 잡혀 NSMetadataQuery가 반드시 필요하다. DirectoryWatcher와 짝을 이뤄 CompositeWatcher로 함께 세운다.
public final class MetadataQueryWatcher: StoreWatching {

    /// 유비쿼티 항목 변경이 감지되면 호출된다. 알림을 시작한 런루프 스레드에서 불릴 수
    /// 있다 — 메인 hop은 `Store.startWatching()`이 처리한다(DirectoryWatcher와 동일).
    public var onChange: (() -> Void)?

    private let fileName: String
    private let directoryURL: URL
    private let notificationCenter: NotificationCenter
    /// `@testable` 접근용으로 internal. 테스트가 이 쿼리를 object로 알림을 게시해
    /// 실제 iCloud 없이도 배선을 결정적으로 검증한다.
    let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - fileURL: 감시할 저장소 파일의 전체 경로. 파일명으로 술어를, 상위 폴더로 스코프를 만든다.
    ///   - notificationCenter: 알림 센터. 테스트가 주입한다(기본 `.default`).
    public init(fileURL: URL, notificationCenter: NotificationCenter = .default) {
        self.fileName = fileURL.lastPathComponent
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.notificationCenter = notificationCenter
    }

    public func start() {
        stop()
        // 유비쿼티 문서/데이터 스코프를 대상 폴더로 한정하고, 파일명으로 술어를 건다.
        // 파일이 아직 실체화되지 않은 자리표시자여도 메타데이터 항목은 존재하므로 안전하다.
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryUbiquitousDataScope,
            directoryURL,
        ]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)

        let fire: (Notification) -> Void = { [weak self] _ in self?.onChange?() }
        for name: NSNotification.Name in [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let token = notificationCenter.addObserver(
                forName: name, object: query, queue: nil, using: fire
            )
            observers.append(token)
        }

        // NSMetadataQuery는 런루프가 있는 스레드(메인)에서 시작해야 안정적이다.
        // 이미 메인이면 즉시, 아니면 메인으로 넘긴다.
        if Thread.isMainThread {
            query.start()
        } else {
            DispatchQueue.main.async { [weak self] in self?.query.start() }
        }
    }

    public func stop() {
        for token in observers { notificationCenter.removeObserver(token) }
        observers.removeAll()
        // 시작한 적 없으면 no-op. 임의 스레드에서 불려도 안전하다.
        query.stop()
    }

    deinit { stop() }
}
