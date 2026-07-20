import Foundation

public struct IACollection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var archiveIdentifier: String?
    public var listURL: URL?
    public var archiveQuery: String
    public var systemImage: String
    public var assetName: String?
    public var remoteImageURL: URL?

    public init(
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

public enum IACollectionStore {
    public static let popular = IACollection(
        id: "popular-librivox",
        title: "Popular LibriVox",
        subtitle: "Frequently downloaded public-domain audio",
        archiveIdentifier: "librivoxaudio",
        listURL: URL(string: "https://archive.org/details/librivoxaudio"),
        archiveQuery: LibriVoxBrowseCategory.popular.archiveQuery,
        systemImage: "waveform",
        assetName: "collection-popular-librivox",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "librivoxaudio")
    )

    public static let featured: [IACollection] = [popular] + browseCollections

    public static var browseCollections: [IACollection] {
        LibriVoxBrowseGroup.categories.map { browseCollection(for: $0) }
    }

    public static var allSelectableCollections: [IACollection] {
        browseCollections + curated
    }

    /// Hand-curated canon collections ported from the Parso Radio catalog.
    /// These use broad creator-based Internet Archive queries against LibriVox.
    public static let greatBooks = IACollection(
        id: "great-books",
        title: "Great Books",
        subtitle: "The canonical authors of the Western tradition, read by LibriVox volunteers",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "iliad_popetranslation_1506_librivox")
    )

    public static let greaterBooks = IACollection(
        id: "greater-books",
        title: "Greater Books",
        subtitle: "A broader literary canon — the world's essential novels, plays, and poetry",
        archiveQuery: CuratedQueries.greaterBooks,
        systemImage: "text.book.closed",
        assetName: "collection-greater-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "prideandprejudice_1005_librivox")
    )

    public static let curated: [IACollection] = [greatBooks, greaterBooks]

    public static func collections(for selectedIDs: Set<String>) -> [IACollection] {
        // Popular LibriVox always first, then the two curated collections,
        // then the remaining 21 browse categories sorted alphabetically.
        let sortedBrowse = browseCollections.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return [popular] + curated + sortedBrowse
    }

    private static func browseCollection(for category: LibriVoxBrowseCategory) -> IACollection {
        IACollection(
            id: category.id,
            title: category.title,
            subtitle: authorSubtitle(for: category.id),
            archiveQuery: category.archiveQuery,
            systemImage: category.systemImage,
            assetName: "collection-\(category.id)",
            remoteImageURL: coverURL(for: category.id)
        )
    }

    private static func authorSubtitle(for categoryID: String) -> String {
        switch categoryID {
        case "lv-general-fiction":
            return "Pansy, Mary Elizabeth Braddon, Hugh Walpole, D. H. Lawrence, Charles Dickens"
        case "lv-science-fiction":
            return "H. G. Wells, Edgar Rice Burroughs, Murray Leinster, H. Beam Piper, Andre Norton"
        case "lv-horror-gothic":
            return "Edgar Allan Poe, H. P. Lovecraft, Bram Stoker, Mary Shelley, Robert Louis Stevenson"
        case "lv-mystery-crime":
            return "Edgar Wallace, Arthur Conan Doyle, R. Austin Freeman, Freeman Wills Crofts, G. K. Chesterton"
        case "lv-adventure":
            return "G. A. Henty, Max Brand, Zane Grey, Alexandre Dumas, Mark Twain"
        case "lv-fantasy-mythology":
            return "Lewis Carroll, George MacDonald, L. Frank Baum, Oscar Wilde, Edgar Rice Burroughs"
        case "lv-romance":
            return "Jane Austen, Victor Hugo, Alexandre Dumas, P. G. Wodehouse, Charlotte Brontë"
        case "lv-satire-humor":
            return "Mark Twain, P. G. Wodehouse, Jane Austen, Jerome K. Jerome, Jonathan Swift"
        case "lv-war-military":
            return "Carl von Clausewitz, Sun Tzu, Julius Caesar, Stephen Crane, Homer"
        case "lv-short-stories":
            return "Luigi Pirandello, Edgar Allan Poe, Arthur Conan Doyle, O. Henry, Mark Twain"
        case "lv-drama-plays":
            return "William Shakespeare, Lynn Riggs, Rudyard Kipling, Goethe, George Bernard Shaw"
        case "lv-travel":
            return "Jules Verne, Mark Twain, Isabella L. Bird, John Muir, Anthony Trollope"
        case "lv-ancient-world":
            return "Aristotle, Homer, Aristophanes, Xenophon, Plato"
        case "lv-poetry":
            return "Dante Alighieri, Edgar Allan Poe, Homer, Edmund Spenser, Walt Whitman"
        case "lv-philosophy-mind":
            return "Friedrich Nietzsche, Plato, Aristotle, Immanuel Kant, Arthur Schopenhauer"
        case "lv-history":
            return "Jacob Abbott, Henrietta Elizabeth Marshall, Edward Gibbon, John H. Haaren, Thucydides"
        case "lv-biography":
            return "Jacob Abbott, Helen Keller, Mark Twain, Benjamin Franklin, Frederick Douglass"
        case "lv-science-nature":
            return "Charles Darwin, John Muir, Michael Faraday, Jean-Henri Fabre, John Burroughs"
        case "lv-religion":
            return "Andrew Murray, Leo Tolstoy, Dante Alighieri, Augustine of Hippo, Charles H. Spurgeon"
        case "lv-essays-ideas":
            return "Ralph Waldo Emerson, Michel de Montaigne, Francis Bacon, G. K. Chesterton, Henry David Thoreau"
        default:
            return "LibriVox public-domain audiobooks"
        }
    }

    private static func coverURL(for categoryID: String) -> URL? {
        switch categoryID {
        case "lv-general-fiction":
            return InternetArchiveMetadata.coverURL(for: "prideandprejudice_1005_librivox")
        case "lv-science-fiction":
            return InternetArchiveMetadata.coverURL(for: "invisible_man_librivox")
        case "lv-horror-gothic":
            return InternetArchiveMetadata.coverURL(for: "dracula_librivox")
        case "lv-mystery-crime":
            return InternetArchiveMetadata.coverURL(for: "american_rivals_sherlock_holmes_1301_librivox")
        case "lv-adventure":
            return InternetArchiveMetadata.coverURL(for: "treasure_island_ap_librivox")
        case "lv-fantasy-mythology":
            return InternetArchiveMetadata.coverURL(for: "grimms_english_librivox")
        case "lv-romance":
            return InternetArchiveMetadata.coverURL(for: "pride_and_prejudice_librivox")
        case "lv-satire-humor":
            return InternetArchiveMetadata.coverURL(for: "bequest_jg_librivox")
        case "lv-war-military":
            return InternetArchiveMetadata.coverURL(for: "on_war_librivox")
        case "lv-short-stories":
            return InternetArchiveMetadata.coverURL(for: "stories_006_librivox")
        case "lv-drama-plays":
            return InternetArchiveMetadata.coverURL(for: "romeo_and_juliet_librivox")
        case "lv-travel":
            return InternetArchiveMetadata.coverURL(for: "swiss_family_robinson_librivox")
        case "lv-ancient-world":
            return InternetArchiveMetadata.coverURL(for: "illiad_0801_librivox3")
        case "lv-poetry":
            return InternetArchiveMetadata.coverURL(for: "poems_every_child_should_know_librivox")
        case "lv-philosophy-mind":
            return InternetArchiveMetadata.coverURL(for: "beyond_good_and_evil_librivox")
        case "lv-history":
            return InternetArchiveMetadata.coverURL(for: "decline_fall_1_0707_librivox")
        case "lv-biography":
            return InternetArchiveMetadata.coverURL(for: "franklin_autobio_gg_librivox")
        case "lv-science-nature":
            return InternetArchiveMetadata.coverURL(for: "origin_species_librivox")
        case "lv-religion":
            return InternetArchiveMetadata.coverURL(for: "divine_comedy_librivox")
        case "lv-essays-ideas":
            return InternetArchiveMetadata.coverURL(for: "walden_librivox")
        default:
            return nil
        }
    }
}

/// Curated Internet Archive Lucene queries for the canon collections.
/// Broad creator-based matching against the LibriVox collection, with a few
/// explicit exclusions for authors who share a name with canonical figures.
public enum CuratedQueries {
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

    public static let greatBooks: String =
        "\(LibriVoxCatalogScope.matching(creatorClause(greatBooksCreators))) \(exclusionClause())"

    public static let greaterBooks: String =
        "\(LibriVoxCatalogScope.matching(creatorClause(greaterBooksCreators))) \(exclusionClause())"

    public static func representativeCreators(forCollectionID id: String) -> [String] {
        let full: [String]
        switch id {
        case "great-books":
            full = greatBooksCreators
        case "greater-books":
            full = greaterBooksCreators
        default:
            return []
        }
        return strideSample(from: full, count: 8)
    }

    private static func strideSample(from list: [String], count: Int) -> [String] {
        guard !list.isEmpty else { return [] }
        let c = min(count, list.count)
        return (0..<c).map { i in
            let index = Int(Double(i) * Double(list.count) / Double(c))
            return list[min(index, list.count - 1)]
        }
    }
}
