import Foundation

struct LibriVoxBrowseGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var categories: [LibriVoxBrowseCategory]

    static let all: [LibriVoxBrowseGroup] = [
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

    static var categories: [LibriVoxBrowseCategory] {
        all.flatMap(\.categories)
    }
}

struct LibriVoxBrowseCategory: Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    var archiveQuery: String

    static let popular = LibriVoxBrowseCategory(
        id: "books-for-you",
        title: "Popular on LibriVox",
        systemImage: "waveform",
        archiveQuery: "mediatype:audio AND collection:librivoxaudio AND downloads:[50 TO *]"
    )

    static let generalFiction = LibriVoxBrowseCategory(
        id: "lv-general-fiction",
        title: "General Fiction",
        systemImage: "book",
        archiveQuery: "collection:librivoxaudio AND (subject:\"General Fiction\" OR subject:\"Culture & Heritage Fiction\" OR subject:\"Family Life\")"
    )

    static let literaryFiction = LibriVoxBrowseCategory(
        id: "lv-literary-fiction",
        title: "Literary Fiction",
        systemImage: "books.vertical",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Literary Fiction\" OR subject:\"Epistolary Fiction\" OR subject:Literature OR subject:\"Literary Collections\")"
    )

    static let scienceFiction = LibriVoxBrowseCategory(
        id: "lv-science-fiction",
        title: "Science Fiction",
        systemImage: "sparkles",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Science Fiction\")"
    )

    static let horrorGothic = LibriVoxBrowseCategory(
        id: "lv-horror-gothic",
        title: "Horror & Gothic",
        systemImage: "moon.stars.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Horror & Supernatural Fiction\" OR subject:Horror OR subject:Gothic OR subject:\"Ghost stories\" OR subject:Supernatural OR subject:\"Gothic Fiction\")"
    )

    static let mysteryCrime = LibriVoxBrowseCategory(
        id: "lv-mystery-crime",
        title: "Mystery & Crime",
        systemImage: "magnifyingglass",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Crime & Mystery Fiction\" OR subject:\"Detective Fiction\")"
    )

    static let adventure = LibriVoxBrowseCategory(
        id: "lv-adventure",
        title: "Adventure",
        systemImage: "map.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Action & Adventure Fiction\" OR subject:\"Historical Fiction\" OR subject:\"Nautical & Marine Fiction\" OR subject:\"Sagas\" OR subject:Westerns)"
    )

    static let fantasyMythology = LibriVoxBrowseCategory(
        id: "lv-fantasy-mythology",
        title: "Fantasy & Mythology",
        systemImage: "wand.and.stars",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Fantasy Fiction\" OR subject:Fantasy OR subject:\"Fairy tales\" OR subject:Mythology OR subject:Myths OR subject:Legends OR subject:Folklore OR subject:\"Fantastic Fiction\")"
    )

    static let romance = LibriVoxBrowseCategory(
        id: "lv-romance",
        title: "Romance",
        systemImage: "heart.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:Romance)"
    )

    static let satireHumor = LibriVoxBrowseCategory(
        id: "lv-satire-humor",
        title: "Satire & Humor",
        systemImage: "face.smiling",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Humorous Fiction\" OR subject:Satire OR subject:Humor)"
    )

    static let warMilitary = LibriVoxBrowseCategory(
        id: "lv-war-military",
        title: "War & Military",
        systemImage: "shield.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"War & Military Fiction\" OR subject:War OR subject:\"World War\" OR subject:Military OR subject:\"World War I\" OR subject:\"World War, 1914-1918\" OR subject:Espionage OR subject:Thrillers)"
    )

    static let shortStories = LibriVoxBrowseCategory(
        id: "lv-short-stories",
        title: "Short Stories",
        systemImage: "text.book.closed",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Short Stories\")"
    )

    static let dramaPlays = LibriVoxBrowseCategory(
        id: "lv-drama-plays",
        title: "Drama & Plays",
        systemImage: "theatermasks.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:Plays OR subject:\"Dramatic Readings\")"
    )

    static let travel = LibriVoxBrowseCategory(
        id: "lv-travel",
        title: "Travel & Exploration",
        systemImage: "airplane",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Travel & Geography\" OR subject:Travel OR subject:\"Voyages and travels\" OR subject:Geography OR subject:Exploration OR subject:\"Travel Fiction\")"
    )

    static let ancientWorld = LibriVoxBrowseCategory(
        id: "lv-ancient-world",
        title: "Ancient World",
        systemImage: "building.columns.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Classics (Greek & Latin Antiquity)\" OR subject:Antiquity)"
    )

    static let poetry = LibriVoxBrowseCategory(
        id: "lv-poetry",
        title: "Poetry",
        systemImage: "text.quote",
        archiveQuery: "collection:librivoxaudio AND (subject:Poetry)"
    )

    static let philosophyMind = LibriVoxBrowseCategory(
        id: "lv-philosophy-mind",
        title: "Philosophy & Mind",
        systemImage: "brain.head.profile",
        archiveQuery: """
        collection:librivoxaudio AND (subject:epistemology OR subject:metaphysics OR subject:ontology OR subject:"political philosophy" OR subject:"philosophy of mind" OR subject:stoicism OR subject:stoic OR subject:utilitarianism OR subject:empiricism OR subject:rationalism OR subject:"german idealism" OR subject:"history of philosophy" OR subject:"ancient philosophy" OR subject:"ancient Greek philosophy" OR subject:"moral philosophy" OR subject:phenomenology OR subject:existentialism OR subject:"natural law" OR subject:pragmatism OR subject:"Indian philosophy" OR subject:"eastern philosophy" OR subject:"Chinese philosophy" OR subject:"Islamic philosophy" OR subject:Confucianism OR subject:Taoism OR subject:neoplatonism OR subject:"medieval philosophy" OR subject:"jewish philosophy" OR subject:psychoanalysis OR (creator:(Plato OR Aristotle OR Kant OR Descartes OR Hume OR Locke OR Spinoza OR Hegel OR Nietzsche OR Schopenhauer OR Leibniz OR "John Stuart Mill" OR Rousseau OR Epicurus OR Epictetus OR "Marcus Aurelius" OR Seneca OR Cicero OR Fichte OR Bergson OR Bentham OR "Francis Bacon" OR "Thomas Hobbes" OR Voltaire OR "John Dewey" OR Russell OR Plotinus OR Boethius OR "Thomas Aquinas" OR Confucius OR "Lao Tzu" OR Maimonides OR Avicenna OR Freud) AND (subject:philosophy OR subject:ethics OR subject:logic OR subject:nonfiction OR subject:"non-fiction" OR subject:metaphysics OR subject:epistemology))) AND NOT (subject:poetry OR subject:fiction OR subject:"science fiction" OR subject:"fairy tales" OR subject:children OR subject:Christmas OR subject:novel OR subject:biography OR subject:autobiography OR subject:"self-help" OR subject:"New Thought" OR subject:"true crime" OR subject:thriller OR subject:mystery OR subject:romance OR subject:adventure OR subject:supernatural OR subject:occult OR subject:mysticism OR subject:hermeticism OR subject:thelema OR subject:yoga OR subject:hypnosis)
        """
    )

    static let history = LibriVoxBrowseCategory(
        id: "lv-history",
        title: "History",
        systemImage: "scroll",
        archiveQuery: "collection:librivoxaudio AND (subject:History OR subject:\"Middle Ages/Middle History\")"
    )

    static let biography = LibriVoxBrowseCategory(
        id: "lv-biography",
        title: "Biography",
        systemImage: "person.text.rectangle",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Biography & Autobiography\" OR subject:Biography OR subject:Autobiography OR subject:Memoirs OR subject:Biographical)"
    )

    static let scienceNature = LibriVoxBrowseCategory(
        id: "lv-science-nature",
        title: "Science & Nature",
        systemImage: "atom",
        archiveQuery: "collection:librivoxaudio AND (subject:Science OR subject:Nature OR subject:\"Life Sciences\" OR subject:\"Astronomy, Physics & Mechanics\" OR subject:\"Nature & Animal Fiction\")"
    )

    static let religion = LibriVoxBrowseCategory(
        id: "lv-religion",
        title: "Religion & Scripture",
        systemImage: "book.closed.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:Religion OR subject:Bibles OR subject:\"Religious Fiction\")"
    )

    static let essaysIdeas = LibriVoxBrowseCategory(
        id: "lv-essays-ideas",
        title: "Essays & Ideas",
        systemImage: "lightbulb",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Essays & Short Works\" OR subject:\"Literary Criticism\" OR subject:\"Political Science\")"
    )

    // MARK: - Lookup & subject mapping

    /// All browse categories (excludes the synthetic `popular`, which carries no
    /// subjects), for lookup and genre mapping.
    static let allCategories: [LibriVoxBrowseCategory] = LibriVoxBrowseGroup.categories

    static func category(withID id: String) -> LibriVoxBrowseCategory? {
        allCategories.first { $0.id == id }
    }

    /// The real archive.org `subject:` strings embedded in `archiveQuery`,
    /// restricted to the positive (non-`AND NOT`) portion so excluded subjects are
    /// never harvested. Used to seed the taste profile from onboarding picks with
    /// terms that actually match archive.org items (unlike the raw `lv-*` id).
    var subjects: [String] {
        let positive = Self.positiveClause(of: archiveQuery)
        return Self.extractSubjects(from: positive)
    }

    /// A small, representative slice of `subjects` for onboarding seeding — enough
    /// to characterize the category without over-diluting the profile via subject
    /// dampening.
    var representativeSubjects: [String] {
        Array(subjects.prefix(3))
    }

    /// Best-effort genre mapping for a book: picks the category whose subject
    /// strings overlap the book's stored subjects the most. Returns `nil` when no
    /// category shares a subject. Used for the Now Playing genre label + the
    /// "More in <Genre>" discovery link.
    static func category(forSubjects bookSubjects: [String]) -> LibriVoxBrowseCategory? {
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
