import Foundation

/// 여러 `StoreWatching`을 하나로 묶어, 자식들의 `onChange`를 단일 `onChange`로
/// 다중화한다.
///
/// iCloud 위치에서는 두 감시자를 함께 세워야 한다: `DirectoryWatcher`(로컬 쓰기 감지)와
/// `MetadataQueryWatcher`(원격 iCloud 반영 감지). 그런데 `Store`는 감시자를 **하나만**
/// 들고 있으므로(`watcher: StoreWatching?`), 이 합성 감시자로 감싸 하나처럼 보이게 한다.
/// 자식 중 누구든 울리면 상위 `onChange`가 울린다.
///
/// 두 감시자가 같은 변경에 대해 둘 다 울려도 무해하다 — 결정 로직
/// (`Store.externalChangeDetected()`)이 지문 비교로 중복 발화를 걸러낸다.
///
/// `StoreWatching` 프로토콜을 그대로 따르므로 `Store`의 감시자 주입/nil화 계약을 깨지
/// 않는다: 테스트와 헤드리스·CLI는 지금까지처럼 nil 감시자나 가짜 감시자를 쓸 수 있다.
// @MX:NOTE: [AUTO] Store는 감시자를 하나만 들 수 있어, iCloud 경로에서 로컬(Directory)+원격(MetadataQuery) 두 감시자를 이 합성기로 하나로 묶는다.
public final class CompositeWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let children: [StoreWatching]

    public init(_ children: [StoreWatching]) {
        self.children = children
        // 각 자식의 onChange를 상위로 전달한다. 클로저는 호출 시점의 self.onChange를
        // 읽으므로, Store가 나중에 onChange를 다시 배선해도 항상 최신 값을 부른다.
        for child in children {
            child.onChange = { [weak self] in self?.onChange?() }
        }
    }

    public func start() { children.forEach { $0.start() } }

    public func stop() { children.forEach { $0.stop() } }
}
