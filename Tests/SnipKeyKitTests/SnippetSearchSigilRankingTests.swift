import XCTest
@testable import SnipKeyKit

/// ⌘/ 검색 팔레트에서 "clear"로 검색해도 `~clear` 스니펫이 제대로 뜨지 않는다는
/// 실제 버그(실사용 라이브러리에서 재현)를 고정하는 테스트.
///
/// 근본 원인: 이 사용자의 약어는 **전부** 트리거 기호(`~`, `!`, `#`, `;`, `@` 등)로
/// 시작한다(실측: 332개 전부). 그런데 `SnippetSearch.score`의 정확·접두 등급은
/// 기호까지 포함한 원본 약어에 대고 `==` / `hasPrefix`를 검사하므로,
/// `"~clear".hasPrefix("clear")`는 항상 false다. 즉 맨몸 단어("clear")로 검색하면
/// 정확 일치(100)·접두 일치(90) 등급이 절대 발동하지 못하고, 약어 단어가 정확히
/// 일치하는 스니펫조차 "약어 중간에 우연히 들어간" 최하 등급(70)으로 떨어진다.
/// 그 결과 단어 접두 일치가 단어 내부(우연한 부분 문자열) 일치보다 낮게/같게
/// 매겨져 순위가 뒤집힌다.
final class SnippetSearchSigilRankingTests: XCTestCase {

    /// 실제 데이터 모양을 그대로 옮긴 픽스처: 약어는 모두 트리거 기호로 시작하고,
    /// `~clearlog`은 %filltext% 매크로를 품은 스니펫이다.
    private func makeGroups() -> [SnippetGroup] {
        [
            SnippetGroup(name: "Misc.", snippets: [
                // 사용자의 실제 ~clear: 약어에 "clear"가 통째로, 내용에도 "clear"가 있다.
                Snippet(
                    abbreviation: "~clear",
                    content: "깃 커밋 앤 푸시하고 메모리에 저장할 거 있으면 저장해. clear 하게.",
                    label: "",
                    caseSensitive: true
                ),
                // %filltext% 매크로 스니펫. 단어 "clear"로 시작(접두)한다.
                Snippet(
                    abbreviation: "~clearlog",
                    content: "%filltext:name=지울 로그%",
                    label: "로그 지우기"
                ),
                // "clear"가 단어 중간에 우연히 들어간 스니펫("unclear").
                Snippet(
                    abbreviation: "~unclear",
                    content: "모호한 부분 표시",
                    label: ""
                ),
                Snippet(abbreviation: "~sig1", content: "Best regards", label: ""),
            ]),
        ]
    }

    private func index(of abbreviation: String, in hits: [SearchHit]) -> Int? {
        hits.firstIndex { $0.snippet.abbreviation == abbreviation }
    }

    // MARK: - 회귀(현재도 통과해야 함)

    func testClearSurfacesClearSnippet() {
        let hits = SnippetSearch.run(query: "clear", in: makeGroups())
        XCTAssertTrue(
            hits.contains { $0.snippet.abbreviation == "~clear" },
            "맨몸 단어 'clear' 검색이 ~clear 스니펫을 반드시 포함해야 한다"
        )
    }

    func testTildeClearRanksClearFirst() {
        let hits = SnippetSearch.run(query: "~clear", in: makeGroups())
        XCTAssertEqual(hits.first?.snippet.abbreviation, "~clear")
    }

    // MARK: - 버그 재현(현재 코드에서 실패해야 함)

    /// 단어 정확 일치(`~clear`)가 단어 접두 일치(`~clearlog`)보다 위여야 한다.
    /// 현재는 둘 다 70점(부분 일치)이라 길이 타이브레이크로만 갈린다.
    func testExactWordOutranksPrefixWord() {
        let hits = SnippetSearch.run(query: "clear", in: makeGroups())
        guard let exact = index(of: "~clear", in: hits),
              let prefix = index(of: "~clearlog", in: hits) else {
            return XCTFail("~clear/~clearlog 둘 다 결과에 있어야 한다")
        }
        XCTAssertLessThan(exact, prefix, "~clear(단어 정확 일치)가 ~clearlog(단어 접두)보다 위여야 한다")
    }

    /// 단어 접두 일치(`~clearlog`)가 단어 내부 우연 일치(`~unclear`)보다 위여야 한다.
    /// 현재 코드: 둘 다 70점 → 더 짧은 `~unclear`가 먼저 와서 순위가 뒤집힌다(실패).
    func testPrefixWordOutranksInternalWord() {
        let hits = SnippetSearch.run(query: "clear", in: makeGroups())
        guard let prefix = index(of: "~clearlog", in: hits),
              let internalMatch = index(of: "~unclear", in: hits) else {
            return XCTFail("~clearlog/~unclear 둘 다 결과에 있어야 한다")
        }
        XCTAssertLessThan(
            prefix, internalMatch,
            "~clearlog(단어 접두 'clear…')가 ~unclear(단어 중간 '…clear…')보다 위여야 한다"
        )
    }
}
