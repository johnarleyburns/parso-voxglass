import Foundation

public struct LibriVoxBrowseGroup: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var categories: [LibriVoxBrowseCategory]

    public static let all: [LibriVoxBrowseGroup] = [
        LibriVoxBrowseGroup(
            id: "fiction",
            title: "Fiction",
            categories: [
                .generalFiction,
                .literaryFiction,
                .scienceFiction,
                .horrorGothic,
                .mysteryCrime,
                .adventure,
                .fantasyMythology,
                .romance,
                .satireHumor,
                .warMilitary
            ]
        ),
        LibriVoxBrowseGroup(
            id: "forms",
            title: "Forms",
            categories: [
                .shortStories,
                .dramaPlays,
                .poetry
            ]
        ),
        LibriVoxBrowseGroup(
            id: "ideas-nonfiction",
            title: "Ideas & Nonfiction",
            categories: [
                .travel,
                .ancientWorld,
                .philosophyMind,
                .history,
                .biography,
                .scienceNature,
                .religion,
                .essaysIdeas
            ]
        )
    ]

    public static var categories: [LibriVoxBrowseCategory] {
        all.flatMap(\.categories)
    }
}

public struct LibriVoxBrowseCategory: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var archiveQuery: String

    public static let popular = LibriVoxBrowseCategory(
        id: "books-for-you",
        title: "Popular on LibriVox",
        systemImage: "waveform",
        archiveQuery: "\(LibriVoxCatalogScope.query) AND downloads:[50 TO *]"
    )

    public static let generalFiction = LibriVoxBrowseCategory(
        id: "lv-general-fiction",
        title: "General Fiction",
        systemImage: "book",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"General Fiction\" OR subject:\"Culture & Heritage Fiction\" OR subject:\"Family Life\"")
    )

    public static let literaryFiction = LibriVoxBrowseCategory(
        id: "lv-literary-fiction",
        title: "Literary Fiction",
        systemImage: "books.vertical",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Literary Fiction\" OR subject:\"Epistolary Fiction\" OR subject:Literature OR subject:\"Literary Collections\"")
    )

    public static let scienceFiction = LibriVoxBrowseCategory(
        id: "lv-science-fiction",
        title: "Science Fiction",
        systemImage: "sparkles",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Science Fiction\"")
    )

    public static let horrorGothic = LibriVoxBrowseCategory(
        id: "lv-horror-gothic",
        title: "Horror & Gothic",
        systemImage: "moon.stars.fill",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Horror & Supernatural Fiction\" OR subject:Horror OR subject:Gothic OR subject:\"Ghost stories\" OR subject:Supernatural OR subject:\"Gothic Fiction\"")
    )

    public static let mysteryCrime = LibriVoxBrowseCategory(
        id: "lv-mystery-crime",
        title: "Mystery & Crime",
        systemImage: "magnifyingglass",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Crime & Mystery Fiction\" OR subject:\"Detective Fiction\"")
    )

    public static let adventure = LibriVoxBrowseCategory(
        id: "lv-adventure",
        title: "Adventure",
        systemImage: "map.fill",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Action & Adventure Fiction\" OR subject:\"Historical Fiction\" OR subject:\"Nautical & Marine Fiction\" OR subject:\"Sagas\" OR subject:Westerns")
    )

    public static let fantasyMythology = LibriVoxBrowseCategory(
        id: "lv-fantasy-mythology",
        title: "Fantasy & Mythology",
        systemImage: "wand.and.stars",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Fantasy Fiction\" OR subject:Fantasy OR subject:\"Fairy tales\" OR subject:Mythology OR subject:Myths OR subject:Legends OR subject:Folklore OR subject:\"Fantastic Fiction\"")
    )

    public static let romance = LibriVoxBrowseCategory(
        id: "lv-romance",
        title: "Romance",
        systemImage: "heart.fill",
        archiveQuery: LibriVoxCatalogScope.matching("subject:Romance")
    )

    public static let satireHumor = LibriVoxBrowseCategory(
        id: "lv-satire-humor",
        title: "Satire & Humor",
        systemImage: "face.smiling",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Humorous Fiction\" OR subject:Satire OR subject:Humor")
    )

    public static let warMilitary = LibriVoxBrowseCategory(
        id: "lv-war-military",
        title: "War & Military",
        systemImage: "shield.fill",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"War & Military Fiction\" OR subject:War OR subject:\"World War\" OR subject:Military OR subject:\"World War I\" OR subject:\"World War, 1914-1918\" OR subject:Espionage OR subject:Thrillers")
    )

    public static let shortStories = LibriVoxBrowseCategory(
        id: "lv-short-stories",
        title: "Short Stories",
        systemImage: "text.book.closed",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Short Stories\"")
    )

    public static let dramaPlays = LibriVoxBrowseCategory(
        id: "lv-drama-plays",
        title: "Drama & Plays",
        systemImage: "theatermasks.fill",
        archiveQuery: LibriVoxCatalogScope.matching("""
        subject:Plays OR subject:"Dramatic Readings" OR subject:Drama OR subject:Tragedy OR subject:Comedy OR subject:Theater OR subject:Theatre OR subject:"One-act plays" OR title:play OR title:drama OR title:tragedy OR title:comedy OR creator:"William Shakespeare" OR creator:"George Bernard Shaw" OR creator:"Sophocles" OR creator:"Euripides" OR creator:"Aeschylus" OR creator:"Aristophanes" OR creator:"Henrik Ibsen" OR creator:"Anton Chekhov" OR creator:"Oscar Wilde" OR creator:"Christopher Marlowe" OR creator:"Molière" OR creator:"Johann Wolfgang von Goethe"
        """)
    )

    public static let travel = LibriVoxBrowseCategory(
        id: "lv-travel",
        title: "Travel & Exploration",
        systemImage: "airplane",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Travel & Geography\" OR subject:Travel OR subject:\"Voyages and travels\" OR subject:Geography OR subject:Exploration OR subject:\"Travel Fiction\"")
    )

    public static let ancientWorld = LibriVoxBrowseCategory(
        id: "lv-ancient-world",
        title: "Ancient World",
        systemImage: "building.columns.fill",
        archiveQuery: LibriVoxCatalogScope.matching("""
        subject:"Classics (Greek & Latin Antiquity)" OR subject:Antiquity OR subject:"Ancient History" OR subject:"Ancient Greece" OR subject:"Ancient Rome" OR subject:Greek OR subject:Latin OR subject:Mythology OR title:ancient OR title:greece OR title:greek OR title:rome OR title:roman OR creator:Homer OR creator:Hesiod OR creator:Aeschylus OR creator:Sophocles OR creator:Euripides OR creator:Aristophanes OR creator:Herodotus OR creator:Thucydides OR creator:Plato OR creator:Aristotle OR creator:Xenophon OR creator:Plutarch OR creator:Virgil OR creator:Ovid OR creator:Tacitus OR creator:Livy OR creator:"Marcus Aurelius" OR creator:Epictetus OR creator:Lucretius OR creator:Cicero
        """)
    )

    public static let poetry = LibriVoxBrowseCategory(
        id: "lv-poetry",
        title: "Poetry",
        systemImage: "text.quote",
        archiveQuery: LibriVoxCatalogScope.matching("subject:Poetry")
    )

    public static let philosophyMind = LibriVoxBrowseCategory(
        id: "lv-philosophy-mind",
        title: "Philosophy & Mind",
        systemImage: "brain.head.profile",
        archiveQuery: """
        \(LibriVoxCatalogScope.query) AND (subject:epistemology OR subject:metaphysics OR subject:ontology OR subject:"political philosophy" OR subject:"philosophy of mind" OR subject:stoicism OR subject:stoic OR subject:utilitarianism OR subject:empiricism OR subject:rationalism OR subject:"german idealism" OR subject:"history of philosophy" OR subject:"ancient philosophy" OR subject:"ancient Greek philosophy" OR subject:"moral philosophy" OR subject:phenomenology OR subject:existentialism OR subject:"natural law" OR subject:pragmatism OR subject:"Indian philosophy" OR subject:"eastern philosophy" OR subject:"Chinese philosophy" OR subject:"Islamic philosophy" OR subject:Confucianism OR subject:Taoism OR subject:neoplatonism OR subject:"medieval philosophy" OR subject:"jewish philosophy" OR subject:psychoanalysis OR (creator:(Plato OR Aristotle OR Kant OR Descartes OR Hume OR Locke OR Spinoza OR Hegel OR Nietzsche OR Schopenhauer OR Leibniz OR "John Stuart Mill" OR Rousseau OR Epicurus OR Epictetus OR "Marcus Aurelius" OR Seneca OR Cicero OR Fichte OR Bergson OR Bentham OR "Francis Bacon" OR "Thomas Hobbes" OR Voltaire OR "John Dewey" OR Russell OR Plotinus OR Boethius OR "Thomas Aquinas" OR Confucius OR "Lao Tzu" OR Maimonides OR Avicenna OR Freud) AND (subject:philosophy OR subject:ethics OR subject:logic OR subject:nonfiction OR subject:"non-fiction" OR subject:metaphysics OR subject:epistemology))) AND NOT (subject:poetry OR subject:fiction OR subject:"science fiction" OR subject:"fairy tales" OR subject:children OR subject:Christmas OR subject:novel OR subject:biography OR subject:autobiography OR subject:"self-help" OR subject:"New Thought" OR subject:"true crime" OR subject:thriller OR subject:mystery OR subject:romance OR subject:adventure OR subject:supernatural OR subject:occult OR subject:mysticism OR subject:hermeticism OR subject:thelema OR subject:yoga OR subject:hypnosis)
        """
    )

    public static let history = LibriVoxBrowseCategory(
        id: "lv-history",
        title: "History",
        systemImage: "scroll",
        archiveQuery: LibriVoxCatalogScope.matching("subject:History OR subject:\"Middle Ages/Middle History\"")
    )

    public static let biography = LibriVoxBrowseCategory(
        id: "lv-biography",
        title: "Biography",
        systemImage: "person.text.rectangle",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Biography & Autobiography\" OR subject:Biography OR subject:Autobiography OR subject:Memoirs OR subject:Biographical")
    )

    public static let scienceNature = LibriVoxBrowseCategory(
        id: "lv-science-nature",
        title: "Science & Nature",
        systemImage: "atom",
        archiveQuery: LibriVoxCatalogScope.matching("subject:Science OR subject:Nature OR subject:\"Life Sciences\" OR subject:\"Astronomy, Physics & Mechanics\" OR subject:\"Nature & Animal Fiction\"")
    )

    public static let religion = LibriVoxBrowseCategory(
        id: "lv-religion",
        title: "Religion & Scripture",
        systemImage: "book.closed.fill",
        archiveQuery: LibriVoxCatalogScope.matching("subject:Religion OR subject:Bibles OR subject:\"Religious Fiction\"")
    )

    public static let essaysIdeas = LibriVoxBrowseCategory(
        id: "lv-essays-ideas",
        title: "Essays & Ideas",
        systemImage: "lightbulb",
        archiveQuery: LibriVoxCatalogScope.matching("subject:\"Essays & Short Works\" OR subject:\"Literary Criticism\" OR subject:\"Political Science\"")
    )

    // MARK: - Lookup & subject mapping

    /// All browse categories (excludes the synthetic `popular`, which carries no
    /// subjects), for lookup and genre mapping.
    public static let allCategories: [LibriVoxBrowseCategory] = LibriVoxBrowseGroup.categories

    public static func category(withID id: String) -> LibriVoxBrowseCategory? {
        allCategories.first { $0.id == id }
    }

    /// The real archive.org `subject:` strings embedded in `archiveQuery`,
    /// restricted to the positive (non-`AND NOT`) portion so excluded subjects are
    /// never harvested. Used to seed the taste profile from onboarding picks with
    /// terms that actually match archive.org items (unlike the raw `lv-*` id).
    public var subjects: [String] {
        let positive = Self.positiveClause(of: archiveQuery)
        return Self.extractSubjects(from: positive)
    }

    /// A small, representative slice of `subjects` for onboarding seeding — enough
    /// to characterize the category without over-diluting the profile via subject
    /// dampening.
    public var representativeSubjects: [String] {
        Array(subjects.prefix(3))
    }

    /// Best-effort genre mapping for a book: picks the category whose subject
    /// strings overlap the book's stored subjects the most. Returns `nil` when no
    /// category shares a subject. Used for the Now Playing genre label + the
    /// "More in <Genre>" discovery link.
    public static func category(forSubjects bookSubjects: [String]) -> LibriVoxBrowseCategory? {
        let normalizedBook = bookSubjects
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !normalizedBook.isEmpty else { return nil }

        var best: LibriVoxBrowseCategory?
        var bestScore = 0
        for category in allCategories {
            var score = 0
            for categorySubject in category.subjects {
                let cs = categorySubject.lowercased()
                for bs in normalizedBook where Self.subjectsMatch(book: bs, category: cs) {
                    score += bs == cs ? 2 : 1
                }
            }
            if score > bestScore {
                bestScore = score
                best = category
            }
        }
        return bestScore > 0 ? best : nil
    }

    private static func subjectsMatch(book: String, category: String) -> Bool {
        if book == category { return true }
        guard category.count >= 4 else { return false }
        return book.contains(category) || category.contains(book)
    }

    private static func positiveClause(of query: String) -> String {
        guard let range = query.range(of: " AND NOT ") else { return query }
        return String(query[query.startIndex..<range.lowerBound])
    }

    private static func extractSubjects(from clause: String) -> [String] {
        let pattern = "subject:(?:\"([^\"]+)\"|([^\\s()\"]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(clause.startIndex..., in: clause)
        var results: [String] = []
        var seen: Set<String> = []
        regex.enumerateMatches(in: clause, range: range) { match, _, _ in
            guard let match else { return }
            let quoted = match.range(at: 1)
            let bare = match.range(at: 2)
            let subjectRange = quoted.location != NSNotFound ? quoted : bare
            guard subjectRange.location != NSNotFound,
                  let swiftRange = Range(subjectRange, in: clause) else { return }
            let subject = String(clause[swiftRange]).trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty, seen.insert(subject.lowercased()).inserted else { return }
            results.append(subject)
        }
        return results
    }
}
