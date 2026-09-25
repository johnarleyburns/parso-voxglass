import Foundation

/// The one matcher for "find a book in My Books from a short phrase" — used by
/// CarPlay's keyboard search (`CarPlayMenuBuilder.myBooksSearchResults`) and by
/// Siri's book lookup (`BookEntityQuery`). Pure and host-testable.
///
/// Every token must appear in the title, an author or a narrator (AND of
/// tokens). Spoken queries carry filler that typed ones rarely do ("the
/// odyssey by homer"), so a few connective words are ignored unless the whole
/// query is made of them. Siri transcriptions also mangle names, so callers can
/// opt into a partial fallback that ranks books matching *some* tokens when no
/// book matches all of them.
public enum LibraryVoiceSearch {
    public struct Candidate: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var authorLine: String
        public var authors: [String]
        public var narrators: [String]

        public init(id: UUID, title: String, authorLine: String, authors: [String], narrators: [String]) {
            self.id = id
            self.title = title
            self.authorLine = authorLine
            self.authors = authors
            self.narrators = narrators
        }
    }

    /// Connective words ignored in a query ("the odyssey by homer").
    static let fillerWords: Set<String> = ["the", "a", "an", "by", "of", "and"]

    public static func tokens(_ query: String) -> [String] {
        let all = query
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        let meaningful = all.filter { !fillerWords.contains($0) }
        return meaningful.isEmpty ? all : meaningful
    }

    /// Candidate IDs, best first. Strict AND-of-tokens; when `allowPartial` is
    /// set and nothing matches every token, books matching at least one token,
    /// ordered by how many tokens they matched.
    public static func rank(query: String, candidates: [Candidate], allowPartial: Bool = false) -> [UUID] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return [] }

        let scored = candidates.map { candidate -> (candidate: Candidate, matched: Int, score: Int) in
            let fields = ([candidate.title, candidate.authorLine] + candidate.authors + candidate.narrators)
                .map { $0.lowercased() }
            let matched = tokens.filter { token in fields.contains { $0.localizedStandardContains(token) } }.count
            return (candidate, matched, score(candidate, tokens: tokens))
        }

        var hits = scored.filter { $0.matched == tokens.count }
        if hits.isEmpty && allowPartial {
            hits = scored.filter { $0.matched > 0 }
        }
        return hits.sorted { lhs, rhs in
            if lhs.matched != rhs.matched { return lhs.matched > rhs.matched }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.title.localizedCaseInsensitiveCompare(rhs.candidate.title) == .orderedAscending
        }
        .map(\.candidate.id)
    }

    private static func score(_ candidate: Candidate, tokens: [String]) -> Int {
        let title = candidate.title.lowercased()
        let authors = ([candidate.authorLine] + candidate.authors).map { $0.lowercased() }
        let narrators = candidate.narrators.map { $0.lowercased() }
        return tokens.reduce(0) { score, token in
            score + (title == token ? 100 : title.hasPrefix(token) ? 50 : title.localizedStandardContains(token) ? 25 : 0)
                + (authors.contains { $0.hasPrefix(token) } ? 15 : 0)
                + (narrators.contains { $0.hasPrefix(token) } ? 15 : 0)
        }
    }
}
