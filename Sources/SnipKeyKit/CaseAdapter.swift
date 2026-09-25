import Foundation

/// 대소문자 따라가기. 스니펫에 `adaptCase`가 켜져 있으면, 사용자가 **실제로 친**
/// 약어의 대소문자를 확장 결과에 옮긴다 (Espanso의 propagate_case, TextExpander의
/// "Adapt to case of abbreviation"과 같은 동작).
///
///   ;sig → best regards    (저장된 그대로)
///   ;Sig → Best regards    (첫 글자만 대문자)
///   ;SIG → BEST REGARDS    (대소문자가 있는 글자 둘 이상이 전부 대문자)
///
/// 대소문자가 없는 문자(한글·숫자·기호)만으로 된 약어는 아무것도 바꾸지 않는다.
public enum CaseAdapter {

    public static func adapt(_ text: String, typed: String, abbreviation: String) -> String {
        guard typed != abbreviation else { return text }
        let cased = typed.filter { $0.isUppercase || $0.isLowercase }
        guard let first = cased.first else { return text }

        if cased.count >= 2, cased.allSatisfy(\.isUppercase) {
            return text.uppercased()
        }
        if first.isUppercase {
            return capitalizingFirstLetter(text)
        }
        return text
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        var result = text
        result.replaceSubrange(index...index, with: String(text[index]).uppercased())
        return result
    }
}
