import Foundation

/// One source-neutral result inside a merged Find response.
public enum MergedSearchCandidate: Identifiable, Equatable, Sendable {
    case libriVox(InternetArchiveSearchResult)
    case readByAI(GutenbergBook)

    public var id: String {
        switch self {
        case .libriVox(let result): "librivox:\(result.identifier)"
        case .readByAI(let book): "gutenberg:\(book.id)"
        }
    }

    public var title: String {
        switch self {
        case .libriVox(let result): result.title
        case .readByAI(let book): book.title
        }
    }

    public var authorLine: String {
        switch self {
        case .libriVox(let result): result.displayAuthorLine ?? result.authorLine
        case .readByAI(let book): book.authorLine
        }
    }

    public var languages: [String] {
        switch self {
        case .libriVox(let result): result.languages
        case .readByAI(let book): book.languages
        }
    }

    public var isHumanNarrated: Bool {
        switch self {
        case .libriVox: true
        case .readByAI: false
        }
    }

    var downloads: Int {
        switch self {
        case .libriVox(let result): result.downloads ?? 0
        case .readByAI: 0
        }
    }
}

/// A primary result plus the other recordings/editions of the same work.
public struct MergedSearchResult: Identifiable, Equatable, Sendable {
    public var id: String
    public var workKey: String
    public var primary: MergedSearchCandidate
    public var alternates: [MergedSearchCandidate]
    public var relevance: Int

    public init(
        id: String,
        workKey: String,
        primary: MergedSearchCandidate,
        alternates: [MergedSearchCandidate],
        relevance: Int
    ) {
        self.id = id
        self.workKey = workKey
        self.primary = primary
        self.alternates = alternates
        self.relevance = relevance
    }
}

/// Combines LibriVox and Gutenberg search results into one relevance-ranked list.
///
/// Human narration wins when it is a credible match. A materially tighter
/// Gutenberg title still wins over a loose LibriVox subject/description match,
/// and Gutenberg-only works are never hidden.
public struct MergedSearchRanker: Sendable {
    /// How much relevance a LibriVox result may give up and still win on the
    /// strength of being human-narrated.
    public static let humanPreferenceWindow = 10

    public init() {}

    public func rank(
        query: String,
        libriVox: [InternetArchiveSearchResult],
        gutenberg: [GutenbergBook],
        preferredLanguages: Set<String> = [],
        limit: Int = 50
    ) -> [MergedSearchResult] {
        let foldedQuery = GutenbergCatalogIndex.fold(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !foldedQuery.isEmpty else { return [] }
        let queryTokens = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !queryTokens.isEmpty else { return [] }

        let preferredCodes = GutenbergLanguagePreference.codes(for: preferredLanguages)
        var seen: Set<String> = []

        var scored: [ScoredCandidate] = []
        for result in libriVox where result.isStrictLibriVoxCatalogCandidate {
            guard seen.insert("librivox:\(result.identifier)").inserted else { continue }
            let candidate = MergedSearchCandidate.libriVox(result)
            let relevance = relevance(
                query: foldedQuery,
                tokens: queryTokens,
                title: result.title,
                author: result.authorLine,
                subjects: result.subjects,
                shelves: []
            )
            scored.append(makeScored(
                candidate,
                relevance: relevance,
                preferredCodes: preferredCodes
            ))
        }
        for book in gutenberg {
            guard seen.insert("gutenberg:\(book.id)").inserted else { continue }
            let candidate = MergedSearchCandidate.readByAI(book)
            let relevance = relevance(
                query: foldedQuery,
                tokens: queryTokens,
                title: book.title,
                author: book.authorLine,
                subjects: book.subjects,
                shelves: []
            )
            scored.append(makeScored(
                candidate,
                relevance: relevance,
                preferredCodes: preferredCodes
            ))
        }

        let grouped = Dictionary(grouping: scored, by: \.workKey)
        var merged: [MergedSearchResult] = []
        for (workKey, candidates) in grouped {
            let human = candidates.filter { $0.candidate.isHumanNarrated }.max(by: isWorse)
            let readByAI = candidates.filter { !$0.candidate.isHumanNarrated }.max(by: isWorse)
            let primary: ScoredCandidate
            if let human, let readByAI {
                primary = human.relevance >= readByAI.relevance - Self.humanPreferenceWindow
                    ? human
                    : readByAI
            } else if let human {
                primary = human
            } else if let readByAI {
                primary = readByAI
            } else {
                continue
            }

            let alternates = candidates
                .filter { $0.candidate.id != primary.candidate.id }
                .sorted(by: isBetter)
                .map(\.candidate)
            merged.append(MergedSearchResult(
                id: "\(workKey)#\(primary.candidate.id)",
                workKey: workKey,
                primary: primary.candidate,
                alternates: alternates,
                relevance: primary.relevance
            ))
        }

        return merged
            .sorted(by: isBetterResult)
            .prefix(limit)
            .map { $0 }
    }

    private struct ScoredCandidate {
        var candidate: MergedSearchCandidate
        var relevance: Int
        var isPreferredLanguage: Bool
        var workKey: String
        var sortTitle: String
    }

    private func makeScored(
        _ candidate: MergedSearchCandidate,
        relevance: Int,
        preferredCodes: Set<String>
    ) -> ScoredCandidate {
        let languageCodes = Set(candidate.languages.map(GutenbergLanguagePreference.normalize))
        return ScoredCandidate(
            candidate: candidate,
            relevance: relevance,
            isPreferredLanguage: !preferredCodes.isEmpty
                && !languageCodes.isDisjoint(with: preferredCodes),
            workKey: workKey(for: candidate),
            sortTitle: GutenbergCatalogIndex.fold(candidate.title)
        )
    }

    private func relevance(
        query: String,
        tokens: [String],
        title: String,
        author: String,
        subjects: [String],
        shelves: [String]
    ) -> Int {
        let fullTitle = GutenbergCatalogIndex.fold(title)
        let core = Self.titleCore(title)
        if core == query { return 100 }
        if core.hasPrefix(query) { return 90 }
        if tokens.allSatisfy({ core.contains($0) }) { return 80 }
        if fullTitle.contains(query) { return 75 }
        if tokens.allSatisfy({ fullTitle.contains($0) }) { return 70 }

        let foldedAuthor = GutenbergCatalogIndex.fold(author)
        if foldedAuthor.contains(query) || tokens.allSatisfy({ foldedAuthor.contains($0) }) {
            return 60
        }

        let foldedSubjects = GutenbergCatalogIndex.fold((subjects + shelves).joined(separator: " "))
        if tokens.allSatisfy({ foldedSubjects.contains($0) }) { return 50 }

        return 40
    }

    private func workKey(for candidate: MergedSearchCandidate) -> String {
        let core = Self.titleCore(candidate.title)
        let author = Self.authorKey(candidate.authorLine)
        return "\(core)|\(author)"
    }

    private func isWorse(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        !isBetter(lhs, rhs)
    }

    private func isBetter(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        if lhs.isPreferredLanguage != rhs.isPreferredLanguage { return lhs.isPreferredLanguage }
        if lhs.candidate.isHumanNarrated != rhs.candidate.isHumanNarrated {
            return lhs.candidate.isHumanNarrated
        }
        if lhs.candidate.downloads != rhs.candidate.downloads {
            return lhs.candidate.downloads > rhs.candidate.downloads
        }
        return lhs.sortTitle < rhs.sortTitle
    }

    private func isBetterResult(_ lhs: MergedSearchResult, _ rhs: MergedSearchResult) -> Bool {
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        if lhs.primary.isHumanNarrated != rhs.primary.isHumanNarrated {
            return lhs.primary.isHumanNarrated
        }
        let leftTitle = GutenbergCatalogIndex.fold(lhs.primary.title)
        let rightTitle = GutenbergCatalogIndex.fold(rhs.primary.title)
        if leftTitle != rightTitle { return leftTitle < rightTitle }
        return lhs.id < rhs.id
    }

    static func titleCore(_ raw: String) -> String {
        var value = GutenbergCatalogIndex.fold(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for article in ["the ", "a ", "an "] where value.hasPrefix(article) {
            value.removeFirst(article.count)
            break
        }

        for separator in [":", ";", "—", "–"] {
            if let range = value.range(of: separator) {
                value = String(value[..<range.lowerBound])
            }
        }

        for marker in [", ou ", ", or ", ", being ", ", a ", ", an ", ", the ",
                       ", vol", ", book", ", part", ", tome", ", translated",
                       ", complete", ", illustrated", ", with "] {
            if let range = value.range(of: marker) {
                value = String(value[..<range.lowerBound])
            }
        }

        for editionWord in [" illustrated", " complete", " unabridged", " annotated",
                            " translation", " translated", " edition", " volume",
                            " vol.", " vol ", " book ", " part ", " tome "] {
            value = value.replacingOccurrences(of: editionWord, with: " ")
        }

        value = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.trimmingCharacters(in: .punctuationCharacters)
    }

    static func authorKey(_ raw: String) -> String {
        var value = GutenbergCatalogIndex.fold(raw)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "unknown" || value == "unknown author" || value.isEmpty {
            return ""
        }
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        } else if let last = value.split(whereSeparator: \.isWhitespace).last {
            value = String(last)
        }
        let cleaned = String(value.filter { $0.isLetter || $0.isWhitespace })
        return cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
