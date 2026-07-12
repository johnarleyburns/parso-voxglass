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

    static let featured: [IACollection] = [popular] + browseCollections

    static var browseCollections: [IACollection] {
        LibriVoxBrowseGroup.categories.map { browseCollection(for: $0) }
    }

    static var allSelectableCollections: [IACollection] {
        browseCollections + curated
    }

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

    static func collections(for selectedIDs: Set<String>) -> [IACollection] {
        let all = [popular] + browseCollections + curated
        return all.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func browseCollection(for category: LibriVoxBrowseCategory) -> IACollection {
        IACollection(
            id: category.id,
            title: category.title,
            subtitle: authorSubtitle(for: category.id),
            archiveQuery: category.archiveQuery,
            systemImage: category.systemImage,
            remoteImageURL: coverURL(for: category.id)
        )
    }

    private static func authorSubtitle(for categoryID: String) -> String {
        switch categoryID {
        case "lv-general-fiction":
            return "Pansy, Mary Elizabeth Braddon, Hugh Walpole, D. H. Lawrence, Charles Dickens"
        case "lv-literary-fiction":
            return "Jane Austen, Mark Twain, Arthur Conan Doyle, Charles Dickens, Oscar Wilde"
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
            return "Sun Tzu, John Buchan, Theodore Roosevelt, Homer, Stephen Crane"
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
            return "Edgar Rice Burroughs, H. G. Wells, Charles Darwin, Andre Norton, Jules Verne"
        case "lv-religion":
            return "Andrew Murray, Leo Tolstoy, Dante Alighieri, Augustine of Hippo, Charles H. Spurgeon"
        case "lv-essays-ideas":
            return "Edmund Burke, G. K. Chesterton, William Hazlitt, Hugh Walpole, George Bernard Shaw"
        default:
            return "LibriVox public-domain audiobooks"
        }
    }

    private static func coverURL(for categoryID: String) -> URL? {
        switch categoryID {
        case "lv-general-fiction":
            return InternetArchiveMetadata.coverURL(for: "prideandprejudice_1005_librivox")
        case "lv-literary-fiction":
            return InternetArchiveMetadata.coverURL(for: "great_expectations_mfs_0812_librivox")
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
            return InternetArchiveMetadata.coverURL(for: "art_of_war_librivox")
        case "lv-short-stories":
            return InternetArchiveMetadata.coverURL(for: "shortstorycollection001_librivox")
        case "lv-drama-plays":
            return InternetArchiveMetadata.coverURL(for: "romeo_and_juliet_librivox")
        case "lv-travel":
            return InternetArchiveMetadata.coverURL(for: "swiss_family_robinson_librivox")
        case "lv-ancient-world":
            return InternetArchiveMetadata.coverURL(for: "iliad_librivox")
        case "lv-poetry":
            return InternetArchiveMetadata.coverURL(for: "poems_every_child_should_know_librivox")
        case "lv-philosophy-mind":
            return InternetArchiveMetadata.coverURL(for: "beyond_good_and_evil_librivox")
        case "lv-history":
            return InternetArchiveMetadata.coverURL(for: "history_of_the_decline_and_fall_01_librivox")
        case "lv-biography":
            return InternetArchiveMetadata.coverURL(for: "autobiography_benjamin_franklin_librivox")
        case "lv-science-nature":
            return InternetArchiveMetadata.coverURL(for: "origin_of_species_librivox")
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
        "collection:librivoxaudio AND (\(creatorClause(greatBooksCreators))) \(exclusionClause())"

    static let greaterBooks: String =
        "collection:librivoxaudio AND (\(creatorClause(greaterBooksCreators))) \(exclusionClause())"

    static let ancientGreece: String =
        "collection:librivoxaudio AND (\(creatorClause(ancientGreeceCreators))) \(exclusionClause())"
}
