import Foundation

/// A snippet plus the group it lives in — search results span every group, so
/// they have to carry that context with them.
public struct SearchHit: Identifiable, Equatable {
    public let snippet: Snippet
    public let groupID: UUID
    public let groupName: String
    /// Higher is a better match. Used for ordering only.
    public let score: Int

    public var id: UUID { snippet.id }

    public init(snippet: Snippet, groupID: UUID, groupName: String, score: Int) {
        self.snippet = snippet
        self.groupID = groupID
        self.groupName = groupName
        self.score = score
    }
}

public enum SnippetSearch {

    /// Searches abbreviation, label, and content — the three fields
    /// TextExpander searches — and ranks the way a person would expect:
    /// an abbreviation you half-remember beats a word buried in some content.
    ///
    /// Ranking, best first:
    ///   1. abbreviation starts with the query
    ///   2. abbreviation contains the query
    ///   3. label starts with / contains the query
    ///   4. content contains the query
    /// Ties break on the shorter abbreviation, then alphabetically, so results
    /// do not jump around between keystrokes.
    ///
    /// 약어는 보통 트리거 기호(`~`, `!`, `#`, `;`, `@`, `/` …)로 시작하므로, 맨몸
    /// 단어로 검색할 때 그 기호가 정확·접두 일치를 막지 않도록 선두 기호를 벗긴
    /// "단어부"에도 같은 등급을 매긴다. 기호까지 쳐서 검색한 경우를 위해 원본 약어
    /// 검사는 그대로 남겨 기존 동작을 보존한다.
    public static func run(
        query: String,
        in groups: [SnippetGroup],
        includeDisabled: Bool = true,
        limit: Int? = nil
    ) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for group in groups {
            for snippet in group.snippets {
                if !includeDisabled && !(snippet.enabled && group.enabled) { continue }
                guard let score = score(snippet: snippet, needle: needle) else { continue }
                hits.append(SearchHit(
                    snippet: snippet,
                    groupID: group.id,
                    groupName: group.name,
                    score: score
                ))
            }
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.snippet.abbreviation.count != b.snippet.abbreviation.count {
                return a.snippet.abbreviation.count < b.snippet.abbreviation.count
            }
            return a.snippet.abbreviation.localizedCaseInsensitiveCompare(b.snippet.abbreviation) == .orderedAscending
        }

        if let limit, hits.count > limit {
            return Array(hits.prefix(limit))
        }
        return hits
    }

    private static func score(snippet: Snippet, needle: String) -> Int? {
        let abbreviation = snippet.abbreviation.lowercased()
        let label = snippet.label.lowercased()
        let content = snippet.content.lowercased()

        // 선두 트리거 기호를 벗긴 약어의 "단어부". "~clear" → "clear".
        let bareAbbreviation = strippingLeadingSigils(abbreviation)

        // 정확·접두 등급은 원본 약어와 단어부 중 하나라도 맞으면 인정한다.
        if abbreviation == needle || bareAbbreviation == needle { return 100 }
        if abbreviation.hasPrefix(needle) || bareAbbreviation.hasPrefix(needle) { return 90 }
        if abbreviation.contains(needle) { return 70 }
        if label.hasPrefix(needle) { return 60 }
        if label.contains(needle) { return 50 }
        if content.contains(needle) { return 30 }
        return nil
    }

    /// 약어 선두의 트리거 기호(영문자·숫자가 아닌 문자)를 벗겨 "단어부"를 돌려준다.
    /// 예: "~clear" → "clear", "!gt1" → "gt1", ";;x" → "x". 기호뿐인 약어는 ""가 된다.
    private static func strippingLeadingSigils(_ abbreviation: String) -> String {
        var rest = Substring(abbreviation)
        while let first = rest.first, !first.isLetter, !first.isNumber {
            rest = rest.dropFirst()
        }
        return String(rest)
    }
}

// MARK: - Store convenience

extension Store {

    public func search(_ query: String, limit: Int? = nil) -> [SearchHit] {
        SnippetSearch.run(query: query, in: groups, limit: limit)
    }

    /// Abbreviations that more than one enabled snippet claims. Two snippets with
    /// the same abbreviation means one of them can never fire, so the editor
    /// warns about it the way TextExpander does.
    public func conflictingAbbreviations() -> Set<String> {
        var seen: [String: Int] = [:]
        for group in groups where group.enabled {
            for snippet in group.snippets where snippet.enabled && !snippet.abbreviation.isEmpty {
                let key = snippet.caseSensitive ? snippet.abbreviation : snippet.abbreviation.lowercased()
                seen[key, default: 0] += 1
            }
        }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    /// The other snippets already using this abbreviation, excluding `excluding`.
    public func snippetsClaiming(abbreviation: String, excluding id: UUID) -> [SearchHit] {
        guard !abbreviation.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for group in groups {
            for snippet in group.snippets
            where snippet.id != id && snippet.abbreviation == abbreviation {
                hits.append(SearchHit(
                    snippet: snippet,
                    groupID: group.id,
                    groupName: group.name,
                    score: 0
                ))
            }
        }
        return hits
    }
}
