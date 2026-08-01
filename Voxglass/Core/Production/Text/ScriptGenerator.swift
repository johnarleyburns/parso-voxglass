import Foundation

public protocol ScriptGenerating: Sendable {
    var destination: DestinationID { get }
    func plan(for project: AudiobookProject) -> ScriptPlan
}

public struct ScriptPlan: Sendable, Equatable {
    public var chapterIntros: [UUID: String]
    public var chapterOutros: [UUID: String]
    public var bookChapters: [SyntheticChapter]

    public init(
        chapterIntros: [UUID: String] = [:],
        chapterOutros: [UUID: String] = [:],
        bookChapters: [SyntheticChapter] = []
    ) {
        self.chapterIntros = chapterIntros
        self.chapterOutros = chapterOutros
        self.bookChapters = bookChapters
    }
}

public struct SyntheticChapter: Sendable, Equatable {
    public var role: ChapterRole
    public var title: String
    public var paragraphText: String
    public var paragraphRole: ParagraphRole

    public init(role: ChapterRole, title: String, paragraphText: String, paragraphRole: ParagraphRole) {
        self.role = role
        self.title = title
        self.paragraphText = paragraphText
        self.paragraphRole = paragraphRole
    }
}

// MARK: - LibriVox

public struct LibriVoxScriptGenerator: ScriptGenerating {
    public var destination: DestinationID { .librivox }
    public let useShortFormAfterFirstSection: Bool

    public init(useShortFormAfterFirstSection: Bool = true) {
        self.useShortFormAfterFirstSection = useShortFormAfterFirstSection
    }

    public func plan(for project: AudiobookProject) -> ScriptPlan {
        let title = project.metadata.title
        let author = project.metadata.author
        let narrator = project.metadata.narrator
        let translator = project.metadata.translator

        let chapters = project.chapters.filter { $0.role == .body || $0.role == .frontMatter || $0.role == .backMatter }
        var intros: [UUID: String] = [:]
        var outros: [UUID: String] = [:]

        for (index, chapter) in chapters.enumerated() {
            let chapterNum = index + 1
            let chapterTitle = chapter.title
            let isFirst = chapterNum == 1

            let intro: String
            if isFirst || !useShortFormAfterFirstSection {
                intro = """
                Chapter \(chapterNum) of \(title). This is a LibriVox recording. All LibriVox recordings are in the public domain. For more information, or to volunteer, please visit librivox dot org.
                Recording by \(narrator).
                \(title), by \(author).\(translator.map { " Translated by \($0)." } ?? "") \(chapterTitleForIntro(chapterTitle, chapterNum: chapterNum, title: title)).
                """
            } else {
                intro = """
                Chapter \(chapterNum) of \(title). This LibriVox recording is in the public domain.
                \(chapterTitleForIntro(chapterTitle, chapterNum: chapterNum, title: title)).
                """
            }

            let outro: String
            if index == chapters.count - 1 {
                outro = """
                End of \(chapterTitleForOutro(chapterTitle, chapterNum: chapterNum, title: title)).
                End of \(title), by \(author).
                """
            } else {
                outro = "End of \(chapterTitleForOutro(chapterTitle, chapterNum: chapterNum, title: title))."
            }

            intros[chapter.id] = intro.trimmingCharacters(in: .whitespacesAndNewlines)
            outros[chapter.id] = outro.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ScriptPlan(chapterIntros: intros, chapterOutros: outros)
    }

    private func chapterTitleForIntro(_ chapterTitle: String, chapterNum: Int, title: String) -> String {
        let normalized = chapterTitle.trimmingCharacters(in: .whitespaces)
        let prefix = "Chapter \(chapterNum)"
        if normalized.isEmpty || normalized == prefix || normalized.caseInsensitiveCompare(title) == .orderedSame {
            return ""
        }
        return " \(normalized)"
    }

    private func chapterTitleForOutro(_ chapterTitle: String, chapterNum: Int, title: String) -> String {
        let normalized = chapterTitle.trimmingCharacters(in: .whitespaces)
        let prefix = "Chapter \(chapterNum)"
        if normalized.isEmpty || normalized == prefix {
            return "Chapter \(chapterNum)"
        }
        return normalized
    }
}

// MARK: - Retail

public struct RetailScriptGenerator: ScriptGenerating {
    public var destination: DestinationID { .acx }

    public init() {}

    public func plan(for project: AudiobookProject) -> ScriptPlan {
        let title = project.metadata.title
        let subtitle = project.metadata.subtitle
        let author = project.metadata.author
        let narrator = project.metadata.narrator
        let rightsHolder = project.metadata.rightsHolder
        let copyrightYear = project.metadata.copyrightYear
        let productionYear = project.metadata.productionYear
        let publisher = project.metadata.publisher

        var openingText = "\(title).\(subtitle.map { " \($0)." } ?? "") Written by \(author). Narrated by \(narrator)."

        let closingLines: [String] = [
            "This has been \(title), written by \(author), narrated by \(narrator).",
            rightsHolder.map { r in copyrightYear.map { y in "Copyright \(y) \(r)." } ?? "Copyright \(r)." },
            publisher.map { p in productionYear.map { y in "Production copyright \(y) \(p)." } ?? "Production copyright \(p)." }
        ].compactMap { $0 }
        let closingText = (closingLines + ["The end."]).joined(separator: "\n")

        let openingChapter = SyntheticChapter(
            role: .openingCredits,
            title: "Opening Credits",
            paragraphText: openingText,
            paragraphRole: .retailOpeningCredits
        )

        let closingChapter = SyntheticChapter(
            role: .closingCredits,
            title: "Closing Credits",
            paragraphText: closingText,
            paragraphRole: .retailClosingCredits
        )

        return ScriptPlan(bookChapters: [openingChapter, closingChapter])
    }
}
