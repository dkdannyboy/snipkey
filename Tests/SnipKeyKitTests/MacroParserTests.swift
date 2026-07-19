import XCTest
@testable import SnipKeyKit

final class MacroParserTests: XCTestCase {

    func testPlainTextPassesThrough() {
        let tokens = MacroParser.parse("hello world")
        XCTAssertEqual(tokens, [.text("hello world")])
    }

    func testURLEncodedKoreanIsNotMisparsed() {
        // Real snippet content contains percent-encoded Korean URLs.
        let content = "https://x.com/?q=%EB%AF%B8%EA%B5%AD 100%certain"
        let tokens = MacroParser.parse(content)
        let rendered = MacroParser.render(tokens: tokens)
        XCTAssertEqual(rendered.text, content)
    }

    func testFillText() {
        let tokens = MacroParser.parse("Download \"%filltext:name=URL%\" now")
        XCTAssertEqual(tokens, [
            .text("Download \""),
            .fillText(name: "URL", defaultValue: ""),
            .text("\" now"),
        ])
        let fields = MacroParser.fillFields(in: tokens)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].name, "URL")

        let rendered = MacroParser.render(tokens: tokens, fillValues: [0: "http://a.b"])
        XCTAssertEqual(rendered.text, "Download \"http://a.b\" now")
    }

    func testFillTextWithDefault() {
        let tokens = MacroParser.parse("%filltext:name=who:default=world%")
        let rendered = MacroParser.render(tokens: tokens)
        XCTAssertEqual(rendered.text, "world")
    }

    func testFillTextDefaultWithColonURL() {
        // 회귀 방지: 예전엔 본문을 ':'로 통째로 쪼개 "https"만 남고 "//example.com"이
        // 옵션으로 잘려 나갔다. 파서가 default=를 탐욕적으로 읽으므로 URL 전체가 살아야 한다.
        let tokens = MacroParser.parse("%filltext:name=url:default=https://example.com%")
        XCTAssertEqual(tokens, [.fillText(name: "url", defaultValue: "https://example.com")])
    }

    func testFillTextDefaultWithColonTime() {
        // 시각 "10:30"의 콜론도 값에 그대로 남아야 한다.
        let tokens = MacroParser.parse("%filltext:name=t:default=10:30%")
        XCTAssertEqual(tokens, [.fillText(name: "t", defaultValue: "10:30")])
    }

    func testFillAreaDefaultWithColon() {
        let tokens = MacroParser.parse("%fillarea:name=n:default=a:b:c%")
        XCTAssertEqual(tokens, [.fillArea(name: "n", defaultValue: "a:b:c")])
    }

    func testFillPopupOptionsBeforeGreedyDefault() {
        // 옵션은 default= '앞부분'에서만 쪼개지고, 기본값은 콜론을 담을 수 있다.
        let tokens = MacroParser.parse("%fillpopup:name=p:Basic:Pro:default=https://a.b%")
        XCTAssertEqual(
            tokens,
            [.fillPopup(name: "p", options: ["Basic", "Pro"], defaultValue: "https://a.b")]
        )
    }

    func testExistingContentWithPlainDefaultUnchanged() {
        // 콜론 없는 기존 콘텐츠는 동작이 동일해야 한다(하위 호환).
        XCTAssertEqual(
            MacroParser.parse("%filltext:name=x:default=y%"),
            [.fillText(name: "x", defaultValue: "y")]
        )
    }

    func testFillPartIncludedByDefault() {
        let content = "A%fillpart:name=p:default=yes% optional%fillpartend% B"
        let tokens = MacroParser.parse(content)
        XCTAssertEqual(MacroParser.render(tokens: tokens).text, "A optional B")
        // Toggled off: field 0 is the part.
        XCTAssertEqual(MacroParser.render(tokens: tokens, fillValues: [0: "no"]).text, "A B")
    }

    func testFillPartFieldNumberingWithInnerFields() {
        let content = "%fillpart:name=p:default=yes%[%filltext:name=inner%]%fillpartend%-%filltext:name=outer%"
        let tokens = MacroParser.parse(content)
        let fields = MacroParser.fillFields(in: tokens)
        XCTAssertEqual(fields.map(\.name), ["p", "inner", "outer"])
        let on = MacroParser.render(tokens: tokens, fillValues: [0: "yes", 1: "X", 2: "Y"])
        XCTAssertEqual(on.text, "[X]-Y")
        let off = MacroParser.render(tokens: tokens, fillValues: [0: "no", 1: "X", 2: "Y"])
        XCTAssertEqual(off.text, "-Y")
    }

    func testNestedSnippetResolution() {
        let lookup: (String) -> String? = { abbrev in
            abbrev == "~acc1" ? "Bank 123-456" : nil
        }
        let resolved = MacroParser.resolveNested("Pay here: %snippet:~acc1% thanks", lookup: lookup)
        XCTAssertEqual(resolved, "Pay here: Bank 123-456 thanks")
    }

    func testNestedSnippetRecursionLimit() {
        // A snippet that references itself must not loop forever.
        let lookup: (String) -> String? = { _ in "loop %snippet:~self%" }
        let resolved = MacroParser.resolveNested("%snippet:~self%", lookup: lookup)
        XCTAssertTrue(resolved.contains("loop"))
    }

    func testUnresolvedNestedSnippetKeptLiteral() {
        let resolved = MacroParser.resolveNested("%snippet:~missing%", lookup: { _ in nil })
        XCTAssertEqual(resolved, "%snippet:~missing%")
    }

    func testClipboardBareKeyword() {
        // Real data: "/Users/x/%clipboard.MP4" — no closing percent.
        let tokens = MacroParser.parse("path/%clipboard.MP4 -vn")
        let rendered = MacroParser.render(tokens: tokens, fillValues: [:], clipboard: "MOVIE")
        XCTAssertEqual(rendered.text, "path/MOVIE.MP4 -vn")
    }

    func testKeyEnter() {
        let tokens = MacroParser.parse("run this%key:enter%")
        let rendered = MacroParser.render(tokens: tokens)
        XCTAssertEqual(rendered.text, "run this")
        XCTAssertEqual(rendered.trailingKeys, ["enter"])
    }

    func testCursorPosition() {
        let tokens = MacroParser.parse("<a>%|</a>")
        let rendered = MacroParser.render(tokens: tokens)
        XCTAssertEqual(rendered.text, "<a></a>")
        XCTAssertEqual(rendered.cursorOffsetFromEnd, 4)
    }

    func testDateMacro() {
        let tokens = MacroParser.parse("Today: %date:yyyy-MM-dd%")
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 12
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let rendered = MacroParser.render(tokens: tokens, fillValues: [:], clipboard: "", now: date)
        XCTAssertEqual(rendered.text, "Today: 2026-07-12")
    }

    func testFillPopup() {
        let tokens = MacroParser.parse("%fillpopup:name=plan:Basic:Pro:default=Pro%")
        let fields = MacroParser.fillFields(in: tokens)
        guard case .popup(let options) = fields[0].kind else {
            return XCTFail("expected popup")
        }
        XCTAssertEqual(options, ["Basic", "Pro"])
        XCTAssertEqual(MacroParser.render(tokens: tokens).text, "Pro")
    }
}
