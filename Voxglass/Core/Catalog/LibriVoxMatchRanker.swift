import Foundation

/// Ranks strict LibriVox candidates for the Gutenberg “does this already
/// exist?” check. Network/search policy stays in `InternetArchiveClient`; this
/// value-only type keeps matching deterministic and testable.
public enum LibriVoxMatchRanker {
    public struct Candidate: Equatable, Sendable {
        public let result: InternetArchiveSearchResult
        public let score: Int

        public init(result: InternetArchiveSearchResult, score: Int) {
            self.result = result
            self.score = score
        }
    }

    public static func rank(
        title: String,
        author: String,
        results: [InternetArchiveSearchResult]
    ) -> [Candidate] {
        let normalizedTitle = normalize(title)
        return results
            .filter(\.isStrictLibriVoxCatalogCandidate)
            .map { result in
                let resultTitle = normalize(result.title)
                let resultAuthors = Set(result.creators.flatMap(personVariants))
                let requestedAuthors = personVariants(author)
                var score = 0
                if resultTitle == normalizedTitle { score += 100 }
                else if resultTitle.contains(normalizedTitle) || normalizedTitle.contains(resultTitle) { score += 55 }
                if !requestedAuthors.isDisjoint(with: resultAuthors) { score += 40 }
                else if resultAuthors.contains(where: { candidate in
                    requestedAuthors.contains { candidate.contains($0) || $0.contains(candidate) }
                }) { score += 20 }
                if resultTitle == normalizedTitle, !requestedAuthors.isDisjoint(with: resultAuthors) { score += 25 }
                return Candidate(result: result, score: score)
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.result.identifier < rhs.result.identifier
            }
    }

    public static func searchQuery(title: String, author: String) -> String {
        let safeTitle = sanitizeForArchive(title)
        let safeAuthor = sanitizeForArchive(author)
        var clauses: [String] = []
        if !safeTitle.isEmpty { clauses.append("title:\"\(safeTitle)\"") }
        if !safeAuthor.isEmpty { clauses.append("creator:\"\(safeAuthor)\"") }
        let matchClause = clauses.isEmpty ? "title:\"\"" : clauses.joined(separator: " OR ")
        return "\(LibriVoxCatalogScope.query) AND (\(matchClause))"
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func personVariants(_ value: String) -> Set<String> {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return [] }
        let words = normalized.split(separator: " ").map(String.init)
        return Set([normalized, words.count == 2 ? words.reversed().joined(separator: " ") : normalized])
    }

    private static func sanitizeForArchive(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .joined(separator: " ")
    }
}
