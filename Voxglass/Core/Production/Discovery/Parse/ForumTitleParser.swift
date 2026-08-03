import Foundation

/// Parses LibriVox forum thread titles (NARRATION_NEEDS_SPEC §3.5) from the
/// observed live conventions:
/// `[WEEKLY POETRY] - <Title> by <Author>`, tags `OPEN`/`[SOLO]`/`[GROUP]`/
/// `[DR]`/`COMPLETE`/`[FULL]`, `~` (proof-listener needed), `[OPEN - US ONLY]`.
/// `COMPLETE`/`[FULL]` threads are skipped.
public struct ForumTitleParser: Sendable {
    public enum ThreadStatus: String, Sendable, Equatable {
        case openNeedsReader
        case proofListenerNeeded
        case complete
        case full
    }

    public struct Parsed: Sendable, Equatable {
        public var title: String?
        public var author: String?
        public var isWeeklyPoem: Bool
        public var status: ThreadStatus
        public var usOnly: Bool
        /// Whether this thread offers a narration opportunity (not complete/full).
        public var isNarratable: Bool

        public init(
            title: String? = nil,
            author: String? = nil,
            isWeeklyPoem: Bool = false,
            status: ThreadStatus = .openNeedsReader,
            usOnly: Bool = false,
            isNarratable: Bool = true
        ) {
            self.title = title
            self.author = author
            self.isWeeklyPoem = isWeeklyPoem
            self.status = status
            self.usOnly = usOnly
            self.isNarratable = isNarratable
        }
    }

    public init() {}

    public func parse(_ rawTitle: String) -> Parsed {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let isWeekly = title.uppercased().contains("[WEEKLY POETRY]")
        let isComplete = title.uppercased().contains("COMPLETE")
        let isFull = title.uppercased().contains("[FULL]")
        let needsProofListener = title.contains("~")
        let usOnly = title.uppercased().contains("US ONLY")

        // Strip bracket tags like [WEEKLY POETRY], [SOLO], [GROUP], [DR],
        // [OPEN], [OPEN - US ONLY], [FULL], [COMPLETE].
        title = title.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^\s*-\s*"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "~", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        let status: ThreadStatus = {
            if isComplete || isFull { return .full }
            if needsProofListener { return .proofListenerNeeded }
            return .openNeedsReader
        }()

        // "<Title> by <Author>"
        var workTitle: String? = title.isEmpty ? nil : title
        var author: String?
        if let range = title.range(of: " by ", options: [.caseInsensitive]) {
            workTitle = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let extracted = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            author = extracted.isEmpty ? nil : extracted
        }

        return Parsed(
            title: workTitle,
            author: author,
            isWeeklyPoem: isWeekly,
            status: status,
            usOnly: usOnly,
            isNarratable: !isComplete && !isFull
        )
    }
}
