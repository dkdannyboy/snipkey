import Foundation

/// 스니펫 편집기의 미리보기 패널을 위한 순수 렌더러.
///
/// 실제 확장(`MacroParser.render`)과는 목적이 다르다. 실제 확장은 사용자가 채운
/// 필인 값, 클립보드 내용, 커서 이동, 트레일링 키 입력까지 부작용을 만든다.
/// 미리보기는 "부작용 없이" — 실제 확장을 트리거하지 않고 — 결과물의 *모양*을
/// 사람이 읽을 수 있게 보여주기만 한다. 그래서 별도의 순수 함수로 둔다.
///
/// TextExpander의 미리보기 관례를 따른다: 아직 값이 없는 필인 필드는 이름을
/// 괄호로 감싸 `(field 1)`처럼 보여주고, 클립보드/중첩 스니펫은 대괄호 자리표시자로
/// 보여준다. 눈에 보이지 않는 토큰(키 입력, 커서 마커)은 아무 것도 남기지 않는다.
public enum MacroPreview {

    /// 스니펫 내용을 사람이 읽을 수 있는 미리보기 문자열로 렌더링한다.
    ///
    /// - Parameters:
    ///   - content: 원본 스니펫 내용(매크로 구문 포함).
    ///   - now: 날짜 매크로에 사용할 기준 시각. 테스트에서 고정 값을 주입해
    ///          날짜 출력이 결정론적이 되도록 반드시 주입 가능해야 한다
    ///          (이 코드베이스는 테스트에서 `Date()` 직접 사용을 금지한다).
    public static func render(_ content: String, now: Date = Date()) -> String {
        let tokens = MacroParser.parse(content)
        var out = ""
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .text(let s):
                out += s

            case .fillText(let name, let def), .fillArea(let name, let def):
                // 값이 있으면 값을, 없으면 필드 이름을 괄호로 — TextExpander가 미리보기에서
                // 이름 없는 기본값 필인을 `(field 1)`처럼 보여주는 것과 같은 관례.
                out += def.isEmpty ? "(\(name))" : def

            case .fillPopup(let name, let options, let def):
                // 기본값 → 첫 번째 옵션 → 이름 순으로, "무엇이 채워질지"를 가장 잘 보여주는 것을 고른다.
                if !def.isEmpty {
                    out += def
                } else if let first = options.first {
                    out += first
                } else {
                    out += "(\(name))"
                }

            case .fillPartStart(_, let defaultOn):
                if defaultOn {
                    // 켜진 섹션: 마커만 버리고 안쪽 내용은 그대로 렌더링한다.
                    i += 1
                    continue
                }
                // 꺼진 섹션: 짝이 되는 fillPartEnd까지(중첩 포함) 통째로 건너뛴다.
                // 짝을 찾지 못하면(끝 마커 누락) 남은 내용을 삼켜 감추기보다 포함하는 쪽이
                // 안전하다 — 마커만 버리고 계속 진행한다.
                if let end = matchingEnd(after: i, in: tokens) {
                    i = end + 1
                    continue
                }
                i += 1
                continue

            case .fillPartEnd:
                // 짝 없는 종료 마커: 눈에 보이는 텍스트가 아니므로 버린다.
                break

            case .snippet(let abbrev):
                // 미리보기는 스토어에서 중첩 스니펫을 실제로 펼치지 않는다. 대신 대괄호
                // 자리표시자로, 여기 다른 스니펫이 들어간다는 것만 알려 준다.
                out += "[\(abbrev)]"

            case .clipboard:
                out += "[clipboard]"

            case .key:
                // 키 입력은 눈에 보이는 텍스트를 만들지 않는다.
                break

            case .cursor:
                // 커서 마커는 보이지 않는다.
                break

            case .date(let format):
                out += formattedDate(format, now: now)
            }
            i += 1
        }
        return out
    }

    /// `startIndex`의 fillPartStart와 짝이 되는 fillPartEnd의 인덱스를 찾는다.
    /// 중첩 깊이를 세어 안쪽 파트의 종료 마커를 잘못 짝짓지 않게 한다.
    /// 짝이 없으면 nil(끝 마커 누락).
    private static func matchingEnd(after startIndex: Int, in tokens: [MacroToken]) -> Int? {
        var depth = 1
        var j = startIndex + 1
        while j < tokens.count {
            switch tokens[j] {
            case .fillPartStart:
                depth += 1
            case .fillPartEnd:
                depth -= 1
                if depth == 0 { return j }
            default:
                break
            }
            j += 1
        }
        return nil
    }

    /// 날짜 포맷을 적용한다. 시스템 로캘/타임존을 쓰는 것은 실제 확장과 동일하게
    /// 맞춘 것이다. 포맷이 비었거나 아무 것도 산출하지 못하면(사실상 잘못된 포맷)
    /// 원본 포맷 문자열을 그대로 보여 준다.
    private static func formattedDate(_ format: String, now: Date) -> String {
        guard !format.isEmpty else { return format }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        let result = formatter.string(from: now)
        return result.isEmpty ? format : result
    }
}
