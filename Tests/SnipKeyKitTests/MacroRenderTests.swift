import XCTest
@testable import SnipKeyKit

/// 실제 확장(`MacroParser.render`)이 미리보기(`MacroPreview`)와 같은 구간 규칙을
/// 따르는지 못 박는다. 예전 render는 켜짐/꺼짐 스위치 하나로 구간을 추적해서,
/// 바깥이 꺼져 있어도 안쪽 구간이 켜지면 내용이 새어 나갔다.
final class MacroRenderTests: XCTestCase {

    private func render(_ content: String, _ values: [Int: String] = [:]) -> String {
        MacroParser.render(tokens: MacroParser.parse(content), fillValues: values).text
    }

    // MARK: - 중첩 선택 구간 (B1)

    func testNestedPartOuterOffSwallowsInnerOn() {
        let content = "X%fillpart:name=o:default=no%a%fillpart:name=i:default=yes%b%fillpartend%c%fillpartend%Y"
        XCTAssertEqual(render(content), "XY")
        XCTAssertEqual(render(content), MacroPreview.render(content))
    }

    func testNestedPartOuterOnInnerOff() {
        let content = "X%fillpart:name=o:default=yes%a%fillpart:name=i:default=no%b%fillpartend%c%fillpartend%Y"
        XCTAssertEqual(render(content), "XacY")
    }

    func testNestedPartUserTogglesOuterOff() {
        let content = "X%fillpart:name=o:default=yes%a%fillpart:name=i:default=yes%b%fillpartend%c%fillpartend%Y"
        let fields = MacroParser.fillFields(in: MacroParser.parse(content))
        let outer = fields.first { $0.name == "o" }!.id
        XCTAssertEqual(render(content, [outer: "no"]), "XY")
    }

    func testOffPartWithoutEndKeepsRemainingText() {
        // 미리보기와 같은 규칙: 끝 표시가 없으면 뒤를 삼키지 않고 포함한다.
        let content = "keep%fillpart:name=p:default=no% and this too"
        XCTAssertEqual(render(content), "keep and this too")
        XCTAssertEqual(render(content), MacroPreview.render(content))
    }

    func testFieldInsideSkippedPartDoesNotShiftLaterValues() {
        let content = "%fillpart:name=p:default=no%%filltext:name=a%%fillpartend%[%filltext:name=b%]"
        let fields = MacroParser.fillFields(in: MacroParser.parse(content))
        let b = fields.first { $0.name == "b" }!.id
        XCTAssertEqual(render(content, [b: "B"]), "[B]")
    }

    // MARK: - 같은 이름의 필드 공유 (F5)

    func testSameNameFieldsAreAskedOnce() {
        let content = "Dear %filltext:name=client%, … thanks, %filltext:name=client%."
        let fields = MacroParser.fillFields(in: MacroParser.parse(content))
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(render(content, [fields[0].id: "Kim"]), "Dear Kim, … thanks, Kim.")
    }

    func testUnnamedFieldsAreNotShared() {
        let content = "%filltext:name=%-%filltext:name=%"
        let fields = MacroParser.fillFields(in: MacroParser.parse(content))
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(render(content, [0: "a", 1: "b"]), "a-b")
    }

    func testDistinctNamesKeepPositionalIDs() {
        let content = "%filltext:name=a%%fillpopup:name=b:x:y%%fillarea:name=c%"
        let fields = MacroParser.fillFields(in: MacroParser.parse(content))
        XCTAssertEqual(fields.map(\.id), [0, 1, 2])
        XCTAssertEqual(render(content, [0: "1", 1: "y", 2: "3"]), "1y3")
    }
}
