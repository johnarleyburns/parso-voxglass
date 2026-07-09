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
        systemImage: "theatermasks.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Humorous Fiction\" OR subject:Satire OR subject:Humor)"
    )

    static let warMilitary = LibriVoxBrowseCategory(
        id: "lv-war-military",
        title: "War & Military",
        systemImage: "shield.lefthalf.filled",
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
        systemImage: "theatermasks",
        archiveQuery: "collection:librivoxaudio AND (subject:Plays OR subject:\"Dramatic Readings\")"
    )

    static let travel = LibriVoxBrowseCategory(
        id: "lv-travel",
        title: "Travel",
        systemImage: "globe",
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
        systemImage: "quote.bubble.fill",
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
        systemImage: "clock.arrow.circlepath",
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
        title: "Religion",
        systemImage: "book.closed.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:Religion OR subject:Bibles OR subject:\"Religious Fiction\")"
    )

    static let essaysIdeas = LibriVoxBrowseCategory(
        id: "lv-essays-ideas",
        title: "Essays & Ideas",
        systemImage: "lightbulb.fill",
        archiveQuery: "collection:librivoxaudio AND (subject:\"Essays & Short Works\" OR subject:\"Literary Criticism\" OR subject:\"Political Science\")"
    )
}
