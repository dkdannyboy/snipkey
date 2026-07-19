import Foundation

/// 채우기(fill-in) 매크로 문자열을 타입이 있는 파라미터로부터 조립하는 순수 함수 묶음.
///
/// UI(ManagerView)의 설정 폼이 이 함수들을 호출해 올바른 매크로 구문을 만든다. 목적은
/// 사용자가 `%filltext:name=…%` 같은 날 구문을 손으로 편집하지 않게 하는 것 —
/// TextExpander가 주는 "필드가 있는 작은 폼"의 친숙함을 재현한다.
///
/// 왜 SnipKeyKit의 순수 함수인가: 문자열 조립 규칙(기본값 생략, 구분자 처리)은 SwiftUI
/// 없이 단위 테스트로 못 박아야 하는 부분이고, MacroParser와의 왕복(round-trip)이
/// 성립하는지 검증해야 하기 때문이다. 파서는 이 변경에서 절대 손대지 않는다.
public enum FillInBuilder {

    /// ':'와 '%'는 이 매크로 문법의 구분자다. 이름/기본값/옵션 토큰 안에 그대로 들어가면
    /// MacroParser가 본문을 ':'로 쪼개(이름·기본값이 잘림) 버리거나 첫 '%'에서 매크로를
    /// 끝내(뒤가 통째로 사라짐) 파싱이 깨진다. 콜론이 든 이름은 애초에 이 문법으로 표현할
    /// 수 없으므로, 조용히 망가뜨리는 대신 두 문자를 제거한다. 이스케이프 문법이 파서에
    /// 없기에(그리고 파서를 건드리지 않기로 했기에) 가장 안전한 규칙은 제거다.
    private static func sanitize(_ token: String) -> String {
        token.filter { $0 != ":" && $0 != "%" }
    }

    /// `%filltext:name=NAME%` 또는 `%filltext:name=NAME:default=DEFAULT%`.
    public static func fillText(name: String, defaultValue: String) -> String {
        let n = sanitize(name)
        let d = sanitize(defaultValue)
        // 기본값이 비면 :default= 절을 생략한다(파서의 literal 재구성과 동일한 규칙).
        return d.isEmpty ? "%filltext:name=\(n)%" : "%filltext:name=\(n):default=\(d)%"
    }

    /// `%fillarea:name=NAME%` 또는 `%fillarea:name=NAME:default=DEFAULT%`.
    public static func fillArea(name: String, defaultValue: String) -> String {
        let n = sanitize(name)
        let d = sanitize(defaultValue)
        return d.isEmpty ? "%fillarea:name=\(n)%" : "%fillarea:name=\(n):default=\(d)%"
    }

    /// `%fillpopup:name=NAME:opt1:opt2:...:default=DEFAULT%`.
    public static func fillPopup(name: String, options: [String], defaultValue: String) -> String {
        let n = sanitize(name)
        // 빈 옵션은 버린다 — 폼이 빈 행으로 시작하므로 사용자가 안 채운 행이 매크로에 빈
        // 파트(::)로 새어 나가지 않게 한다.
        let opts = options.map(sanitize).filter { !$0.isEmpty }
        let d = sanitize(defaultValue)
        var body = "name=\(n)"
        for o in opts { body += ":\(o)" }
        // 기본값은 비어 있지 않을 때만 싣는다. 옵션에 없는 값이어도 파서가 default=를
        // 위치와 무관하게 읽으므로 그대로 실어 보낸다.
        if !d.isEmpty { body += ":default=\(d)" }
        return "%fillpopup:\(body)%"
    }

    /// `%fillpart:name=NAME:default=yes%CONTENT%fillpartend%`.
    public static func fillPart(name: String, includeByDefault: Bool, content: String) -> String {
        let n = sanitize(name)
        // 내용(content)은 정제하지 않는다 — 선택 구간 안에는 다른 매크로가 들어갈 수 있고
        // 파서도 이 부분을 독립적으로 다시 파싱하기 때문이다. 시작 매크로와 %fillpartend%
        // 사이에 그대로 감싼다.
        let flag = includeByDefault ? "yes" : "no"
        return "%fillpart:name=\(n):default=\(flag)%\(content)%fillpartend%"
    }
}
