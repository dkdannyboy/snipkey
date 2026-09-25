import Foundation

/// 새 약어 이름 짓기.
public enum AbbreviationNaming {

    /// 복제본의 약어. 원본 뒤에 아직 안 쓰인 가장 작은 번호(2, 3, …)를 붙인다.
    ///
    /// 원본 약어가 비어 있으면 복제본도 비워 둔다. 예전에는 "" + "2" = "2"가 되어,
    /// 사용자가 숫자 2 뒤에 스페이스를 칠 때마다 그 스니펫이 확장됐다.
    public static func duplicate(of abbreviation: String, taken: Set<String>) -> String {
        guard !abbreviation.isEmpty else { return "" }
        var n = 2
        while taken.contains(abbreviation + String(n)) { n += 1 }
        return abbreviation + String(n)
    }
}
