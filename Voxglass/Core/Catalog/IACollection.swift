import Foundation

struct IACollection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var archiveIdentifier: String?
    var listURL: URL?
    var archiveQuery: String
    var systemImage: String
    var assetName: String?
    var remoteImageURL: URL?

    init(
        id: String,
        title: String,
        subtitle: String,
        archiveIdentifier: String? = nil,
        listURL: URL? = nil,
        archiveQuery: String,
        systemImage: String,
        assetName: String? = nil,
        remoteImageURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.archiveIdentifier = archiveIdentifier
        self.listURL = listURL
        self.archiveQuery = archiveQuery
        self.systemImage = systemImage
        self.assetName = assetName
        self.remoteImageURL = remoteImageURL
    }
}

enum IACollectionStore {
    static let popular = IACollection(
        id: "popular-librivox",
        title: "Popular LibriVox",
        subtitle: "Frequently downloaded public-domain audio",
        archiveIdentifier: "librivoxaudio",
        listURL: URL(string: "https://archive.org/details/librivoxaudio"),
        archiveQuery: LibriVoxBrowseCategory.popular.archiveQuery,
        systemImage: "waveform",
        assetName: "lv-popular",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "librivoxaudio")
    )

    static let featured: [IACollection] = [
        popular,
        collection(for: LibriVoxTaste.all[0], subtitle: "Canonical fiction, drama, and ancient works", assetName: "lv-classics"),
        collection(for: LibriVoxTaste.all[1], subtitle: "Detectives, clues, and crimes", assetName: "lv-mystery"),
        collection(for: LibriVoxTaste.all[2], subtitle: "Speculative fiction from early audio catalogs", assetName: "lv-sci-fi"),
        collection(for: LibriVoxTaste.all[3], subtitle: "Gothic and supernatural shelves", assetName: "lv-horror")
    ]

    /// Hand-curated canon collections ported from the Parso Radio catalog.
    /// These use broad creator-based Internet Archive queries against LibriVox.
    static let greatBooks = IACollection(
        id: "great-books",
        title: "Great Books",
        subtitle: "The canonical authors of the Western tradition, read by LibriVox volunteers",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "lv-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "iliad_popetranslation_1506_librivox")
    )

    static let greaterBooks = IACollection(
        id: "greater-books",
        title: "Greater Books",
        subtitle: "A broader literary canon — the world's essential novels, plays, and poetry",
        archiveQuery: CuratedQueries.greaterBooks,
        systemImage: "text.book.closed",
        assetName: "lv-greater-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "prideandprejudice_1005_librivox")
    )

    static let ancientGreece = IACollection(
        id: "ancient-greece",
        title: "Ancient Greece",
        subtitle: "Homer, Plato, the tragedians, and more from the Greek world",
        archiveQuery: CuratedQueries.ancientGreece,
        systemImage: "building.columns",
        assetName: "lv-ancient-greece",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "odyssey_pope_librivox")
    )

    static let curated: [IACollection] = [greatBooks, greaterBooks, ancientGreece]

    static func collections(for selectedTasteIDs: Set<String>) -> [IACollection] {
        let selected = LibriVoxTaste.selected(from: selectedTasteIDs)
        guard !selected.isEmpty else {
            return [popular] + curated + Array(featured.dropFirst())
        }

        let preferenceCollections = selected.map { taste in
            collection(for: taste, subtitle: "Based on your \(taste.title.lowercased()) preference")
        }
        return [popular] + curated + preferenceCollections
    }

    static func collection(
        for taste: LibriVoxTaste,
        subtitle: String,
        assetName: String? = nil
    ) -> IACollection {
        IACollection(
            id: "taste-\(taste.id)",
            title: taste.title,
            subtitle: subtitle,
            archiveQuery: taste.archiveQuery,
            systemImage: taste.systemImage,
            assetName: assetName ?? "lv-\(taste.id)",
            remoteImageURL: representativeCoverURL(for: taste.id)
        )
    }

    private static func representativeCoverURL(for tasteID: String) -> URL? {
        switch tasteID {
        case "classics":
            return InternetArchiveMetadata.coverURL(for: "iliad_librivox")
        case "mystery":
            return InternetArchiveMetadata.coverURL(for: "adventuresofsherlockholmes_1110_librivox")
        case "sci-fi":
            return InternetArchiveMetadata.coverURL(for: "time_machine_librivox")
        case "horror":
            return InternetArchiveMetadata.coverURL(for: "dracula_librivox")
        case "romance":
            return InternetArchiveMetadata.coverURL(for: "pride_and_prejudice_librivox")
        case "history":
            return InternetArchiveMetadata.coverURL(for: "history_of_the_decline_and_fall_01_librivox")
        case "philosophy":
            return InternetArchiveMetadata.coverURL(for: "republic_librivox")
        case "poetry":
            return InternetArchiveMetadata.coverURL(for: "poems_every_child_should_know_librivox")
        case "short-stories":
            return InternetArchiveMetadata.coverURL(for: "shortstorycollection001_librivox")
        case "biography":
            return InternetArchiveMetadata.coverURL(for: "autobiography_benjamin_franklin_librivox")
        default:
            return nil
        }
    }
}

/// Curated Internet Archive Lucene queries for the canon collections.
/// Broad creator-based matching against the LibriVox collection, with a few
/// explicit exclusions for authors who share a name with canonical figures.
enum CuratedQueries {
    private static let greatBooksCreators = [
        "Homer", "Aeschylus", "Sophocles", "Euripides", "Aristophanes",
        "Herodotus", "Thucydides", "Plato", "Aristotle", "Hippocrates",
        "Galen", "Lucretius", "Epictetus", "Marcus Aurelius", "Virgil",
        "Plutarch", "Tacitus", "Ptolemy", "Plotinus", "Augustine",
        "Thomas Aquinas", "Dante Alighieri", "Geoffrey Chaucer", "Niccolò Machiavelli",
        "Thomas Hobbes", "François Rabelais", "Michel de Montaigne", "William Shakespeare",
        "Galileo Galilei", "William Gilbert", "William Harvey", "Miguel de Cervantes",
        "Francis Bacon", "René Descartes", "Baruch Spinoza", "John Milton",
        "Blaise Pascal", "Isaac Newton", "Christiaan Huygens", "John Locke",
        "George Berkeley", "David Hume", "Jonathan Swift", "Laurence Sterne",
        "Henry Fielding", "Montesquieu", "Jean-Jacques Rousseau", "Adam Smith",
        "Edward Gibbon", "Immanuel Kant", "Alexander Hamilton", "John Stuart Mill",
        "James Boswell", "Antoine Lavoisier", "Michael Faraday", "Georg Wilhelm Friedrich Hegel",
        "Johann Wolfgang von Goethe", "Herman Melville", "Charles Darwin", "Karl Marx",
        "Leo Tolstoy", "Fyodor Dostoevsky", "William James", "Sigmund Freud",
        "Johannes Kepler"
    ]

    private static let greaterBooksCreators = [
        "Homer", "Sophocles", "Euripides", "Aristophanes", "Virgil", "Ovid",
        "Dante Alighieri", "Geoffrey Chaucer", "Miguel de Cervantes", "William Shakespeare",
        "Christopher Marlowe", "Molière", "John Milton", "Daniel Defoe", "Jonathan Swift",
        "Henry Fielding", "Voltaire", "Jane Austen", "Mary Shelley", "Walter Scott",
        "Lord Byron", "John Keats", "William Blake", "William Wordsworth", "Edgar Allan Poe",
        "Nathaniel Hawthorne", "Herman Melville", "Walt Whitman", "Henry David Thoreau",
        "Emily Brontë", "Charlotte Brontë", "Charles Dickens", "George Eliot", "Thomas Hardy",
        "Lewis Carroll", "Robert Louis Stevenson", "Bram Stoker", "Oscar Wilde",
        "Rudyard Kipling", "Arthur Conan Doyle", "Jules Verne", "H. G. Wells", "Mark Twain",
        "Frederick Douglass", "Victor Hugo", "Alexandre Dumas", "Gustave Flaubert",
        "Émile Zola", "Fyodor Dostoevsky", "Leo Tolstoy", "Anton Chekhov",
        "Alexander Pushkin", "Nikolai Gogol", "Henrik Ibsen", "Joseph Conrad", "Henry James"
    ]

    private static let ancientGreeceCreators = [
        "Homer", "Hesiod", "Aeschylus", "Sophocles", "Euripides", "Aristophanes",
        "Herodotus", "Thucydides", "Plato", "Aristotle", "Sappho", "Plutarch",
        "Xenophon", "Epictetus", "Plotinus"
    ]

    private static let excludedCreators = [
        "William John Locke", "Homer Greene", "Homer Eon Flint"
    ]

    private static func creatorClause(_ creators: [String]) -> String {
        creators.map { "creator:\"\($0)\"" }.joined(separator: " OR ")
    }

    private static func exclusionClause() -> String {
        excludedCreators.map { "AND NOT creator:\"\($0)\"" }.joined(separator: " ")
    }

    static let greatBooks: String =
        "collection:librivoxaudio AND language:eng AND (\(creatorClause(greatBooksCreators))) \(exclusionClause())"

    static let greaterBooks: String =
        "collection:librivoxaudio AND language:eng AND (\(creatorClause(greaterBooksCreators))) \(exclusionClause())"

    static let ancientGreece: String =
        "collection:librivoxaudio AND (\(creatorClause(ancientGreeceCreators))) \(exclusionClause())"
}
