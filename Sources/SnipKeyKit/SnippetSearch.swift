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

        if abbreviation == needle { return 100 }
        if abbreviation.hasPrefix(needle) { return 90 }
        if abbreviation.contains(needle) { return 70 }
        if label.hasPrefix(needle) { return 60 }
        if label.contains(needle) { return 50 }
        if content.contains(needle) { return 30 }
        return nil
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
