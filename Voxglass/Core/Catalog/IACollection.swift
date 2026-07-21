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
    public var curatedListName: String?
    public var summaryLine: String
    public var description: String

    public var isCurated: Bool { curatedListName != nil }
    public var hasDescription: Bool { !description.isEmpty }

    public init(
        id: String,
        title: String,
        subtitle: String,
        archiveIdentifier: String? = nil,
        listURL: URL? = nil,
        archiveQuery: String,
        systemImage: String,
        assetName: String? = nil,
        remoteImageURL: URL? = nil,
        curatedListName: String? = nil,
        summaryLine: String = "",
        description: String = ""
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
        self.curatedListName = curatedListName
        self.summaryLine = summaryLine
        self.description = description
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
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "librivoxaudio"),
        summaryLine: "The most-downloaded public-domain audiobooks from LibriVox, refreshed with every release.",
        description: """
            Popular LibriVox surfaces the most frequently downloaded audiobooks across the entire LibriVox catalog — thousands of hours of public-domain literature, science, philosophy, and more, all read by volunteers.

            LibriVox was founded in 2005 by Hugh McGuire as a volunteer-driven project to make public-domain books freely available as audiobooks. Today the catalog spans over 18,000 completed works in more than 30 languages, all contributed by a global community of volunteer readers and proof-listeners. Every recording is released into the public domain and hosted permanently by the non-profit Internet Archive at [archive.org/details/librivoxaudio](https://archive.org/details/librivoxaudio).

            This Popular collection is the best entry point for new listeners. It mixes perennial favorites like \u{201c}Pride and Prejudice,\u{201d} \u{201c}Moby-Dick,\u{201d} and \u{201c}The Adventures of Sherlock Holmes\u{201d} with community-shared gems discovered through the LibriVox forum and catalog. The ranking reflects organic listener demand and changes as new recordings are released.
            """
    )

    public static let featured: [IACollection] = [popular] + browseCollections

    public static var browseCollections: [IACollection] {
        LibriVoxBrowseGroup.categories.map { browseCollection(for: $0) }
    }

    public static var allSelectableCollections: [IACollection] {
        browseCollections + curated
    }

    /// Curated canon collections generated via enumerated Internet Archive creator queries
    /// against the LibriVox catalog. The set of works is drawn from the
    /// Great Books of the Western World (2nd ed., 1990). Each collection is scoped to
    /// a single language to keep browsing results predictable.
    public static let greatBooks = IACollection(
        id: "great-books",
        title: "Great Books",
        subtitle: "The canonical authors of the Western tradition, read by LibriVox volunteers",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "iliad_popetranslation_1506_librivox"),
        curatedListName: "great-books",
        summaryLine: "405 LibriVox recordings spanning 102 works from the Great Books of the Western World, in English.",
        description: """
            This curated collection traces the intellectual and literary foundations of the Western tradition through a selection of works drawn from the [Great Books of the Western World](https://en.wikipedia.org/wiki/Great_Books_of_the_Western_World) (second edition, 1990), the 60-volume canon assembled by Mortimer Adler and a team of scholars at the University of Chicago.

            The Great Books set spans nearly three millennia of thought: from Homer\u{2019}s epic poems and the tragedies of Aeschylus, Sophocles, and Euripides, through the philosophy of Plato and Aristotle, the histories of Herodotus and Thucydides, the natural science of Hippocrates, Galen, and Archimedes, and on into the medieval and Renaissance syntheses of Augustine, Aquinas, Dante, and Chaucer. It continues through the scientific revolution with Copernicus, Kepler, Galileo, Bacon, Descartes, and Newton; the Enlightenment with Locke, Hume, Montesquieu, Rousseau, Smith, and Kant; the American founding documents and \u{201c}The Federalist Papers\u{201d}; and the 19th and early 20th centuries with Goethe, Austen, Darwin, Marx, Tolstoy, Dostoevsky, Nietzsche, William James, Freud, and Einstein, among others.

            Each entry in this collection links to a specific LibriVox recording of the work. Where no LibriVox recording yet exists for a required Great Books work (e.g. the mathematical treatises of Euclid, Archimedes, and Apollonius, or certain scientific works of Ptolemy, Copernicus, and Kepler), that work is noted but omitted from the listening list.

            The LibriVox volunteer community has recorded many of these works multiple times, in different translations and by different readers. This English-language collection is the most comprehensive, but companion collections for Spanish, German, Italian, and Ancient Greek are also available.
            """
    )

    public static let greatBooksSpanish = IACollection(
        id: "great-books-spa",
        title: "Grandes Libros",
        subtitle: "Los autores del canon occidental leídos por voluntarios de LibriVox",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "donquijote_2507_librivox"),
        curatedListName: "great-books-spa",
        summaryLine: "33 grabaciones de LibriVox de 18 obras de los Grandes Libros del Mundo Occidental, en español.",
        description: """
            Esta colección recorre los fundamentos intelectuales y literarios de la tradición occidental a través de una selección de obras extraídas de los [Grandes Libros del Mundo Occidental](https://en.wikipedia.org/wiki/Great_Books_of_the_Western_World) (segunda edición, 1990).

            Incluye grabaciones en español de Homero, Sófocles, Eurípides, Heródoto, Platón, Marco Aurelio, Dante, Maquiavelo, Shakespeare, Cervantes, Voltaire, Goethe, Dickens, Mark Twain, Tolstói, Conrad, Proust y Kafka.

            La comunidad de voluntarios de LibriVox ha grabado muchas de estas obras en múltiples versiones y traducciones. Esta colección en español complementa la colección principal en inglés.
            """
    )

    public static let greatBooksGerman = IACollection(
        id: "great-books-deu",
        title: "Große Bücher",
        subtitle: "Die kanonischen Autoren der westlichen Tradition, gelesen von LibriVox-Freiwilligen",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "faust1_1012_librivox"),
        curatedListName: "great-books-deu",
        summaryLine: "28 LibriVox-Aufnahmen aus 17 Werken der Great Books of the Western World, auf Deutsch.",
        description: """
            Diese Sammlung zeichnet die geistigen und literarischen Grundlagen der westlichen Tradition nach, basierend auf den [Great Books of the Western World](https://en.wikipedia.org/wiki/Great_Books_of_the_Western_World) (2. Auflage, 1990).

            Enthält deutschsprachige Aufnahmen von Homer, Euripides, Thukydides, Platon, Erasmus, Cervantes, Swift, Voltaire, Goethe, Kant, Marx, Nietzsche, Mark Twain, Tolstoi, Freud und Kafka.

            Die LibriVox-Gemeinschaft hat viele dieser Werke in verschiedenen Übersetzungen eingelesen. Diese deutschsprachige Sammlung ergänzt die englische Hauptsammlung.
            """
    )

    public static let greatBooksItalian = IACollection(
        id: "great-books-ita",
        title: "Grandi Libri",
        subtitle: "Gli autori canonici della tradizione occidentale letti dai volontari di LibriVox",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "divina_commedia_librivox"),
        curatedListName: "great-books-ita",
        summaryLine: "13 registrazioni LibriVox da 4 opere dei Grandi Libri del Mondo Occidentale, in italiano.",
        description: """
            Questa collezione ripercorre le fondamenta intellettuali e letterarie della tradizione occidentale attraverso una selezione di opere tratte dai [Grandi Libri del Mondo Occidentale](https://en.wikipedia.org/wiki/Great_Books_of_the_Western_World) (seconda edizione, 1990).

            Include registrazioni in italiano di Dante Alighieri, Niccolò Machiavelli, Galileo Galilei e Luigi Pirandello.

            La comunità di volontari di LibriVox ha registrato molte di queste opere in versioni multiple. Questa collezione in italiano integra la collezione principale in inglese.
            """
    )

    public static let greatBooksGreek = IACollection(
        id: "great-books-grc",
        title: "Μεγάλα Βιβλία",
        subtitle: "Οι κανονικοί συγγραφείς της δυτικής παράδοσης από εθελοντές του LibriVox",
        archiveQuery: CuratedQueries.greatBooks,
        systemImage: "books.vertical",
        assetName: "collection-great-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "odyssey01_1711_librivox"),
        curatedListName: "great-books-grc",
        summaryLine: "30 LibriVox recordings from 3 works of the Great Books of the Western World, in Ancient Greek.",
        description: """
            This collection presents works from the [Great Books of the Western World](https://en.wikipedia.org/wiki/Great_Books_of_the_Western_World) (2nd edition, 1990) in their original Ancient Greek.

            Includes recordings of Homer's Odyssey (all 24 books), Thucydides' Histories (books 1–7), and Plato's Apology and Definitions.

            LibriVox volunteers have contributed these recordings in the original language, making them a valuable resource for students and scholars of classical Greek. This collection complements the English-language Great Books collection.
            """
    )

    public static let greaterBooks = IACollection(
        id: "greater-books",
        title: "Greater Books",
        subtitle: "A broader literary canon \u{2014} the world\u{2019}s essential novels, plays, and poetry",
        archiveQuery: CuratedQueries.greaterBooks,
        systemImage: "text.book.closed",
        assetName: "collection-greater-books",
        remoteImageURL: InternetArchiveMetadata.coverURL(for: "prideandprejudice_1005_librivox"),
        curatedListName: "greater-books",
        summaryLine: "A hand-curated selection of over 450 essential literary works from Homer to Henry James, sourced from the greaterbooks.com canon.",
        description: """
            This collection draws from the Greater Books shortlist at [greaterbooks.com](https://greaterbooks.com) \u{2014} an open-source literary canon that extends the Great Books tradition into a broader, more inclusive survey of world literature. Unlike the 60-volume Great Books set, which is weighted toward philosophy and natural science, the Greater Books list emphasizes novels, plays, and poetry from the ancient world through the early 20th century.

            The collection spans roughly 2,800 years: the epics of Homer and Virgil, the tragedies and comedies of classical Athens, the medieval visions of Dante and Chaucer, the plays of Shakespeare and his contemporaries Marlowe and Moli\u{00E8}re, the early novels of Cervantes, Defoe, and Fielding, the 19th-century triumphs of Austen, the Bront\u{00EB}s, Dickens, Eliot, Melville, Hawthorne, Flaubert, Dostoevsky, and Tolstoy, and the transitional moderns \u{2014} Conrad, Henry James, Chekhov, Ibsen, Kipling, Wilde, and Wells.

            Every entry in the list links to a specific LibriVox recording, chosen for readability and recording quality from the many versions contributed by the volunteer community. When multiple translations exist, preference is given to English recordings that preserve the character of the original. Browsing by Curation Order follows the greaterbooks.com reading sequence, which is organized by period and tradition.
            """
    )

    public static let curated: [IACollection] = [
        greatBooks, greatBooksSpanish, greatBooksGerman, greatBooksItalian, greatBooksGreek,
        greaterBooks
    ]

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
            remoteImageURL: coverURL(for: category.id),
            summaryLine: collectionSummaryLine(for: category.id),
            description: collectionDescription(for: category.id)
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

    private static func collectionSummaryLine(for categoryID: String) -> String {
        switch categoryID {
        case "lv-general-fiction":
            return "Classic novels and literary fiction from the 18th and 19th centuries, including Austen, Dickens, and the Bront\u{00EB}s."
        case "lv-science-fiction":
            return "Early speculative fiction, space exploration, and scientific romance from Wells, Verne, Burroughs, and more."
        case "lv-horror-gothic":
            return "Gothic tales, supernatural thrillers, and pioneering horror from Shelley, Stoker, Poe, and Lovecraft."
        case "lv-mystery-crime":
            return "Classic detective stories, whodunits, and true crime from Doyle, Chesterton, Wallace, and Green."
        case "lv-adventure":
            return "High-seas voyages, frontier tales, and daring quests from Dumas, Henty, Stevenson, and Twain."
        case "lv-fantasy-mythology":
            return "Fairy tales, myths, legends, and early fantasy fiction from Carroll, Baum, the Brothers Grimm, and Wilde."
        case "lv-romance":
            return "Love, courtship, and the comedy of manners in classic novels from Austen, Bront\u{00EB}, Hugo, and Dumas."
        case "lv-satire-humor":
            return "Wit, irony, and social commentary from Swift, Twain, Wodehouse, Jerome, and Voltaire."
        case "lv-war-military":
            return "Military strategy, wartime memoirs, and historical accounts from Clausewitz, Sun Tzu, Caesar, and Crane."
        case "lv-short-stories":
            return "Brief literary gems by Poe, Chekhov, Maupassant, O. Henry, Saki, and dozens of LibriVox short-story collections."
        case "lv-drama-plays":
            return "The great stage works of Western drama: Shakespeare, Sophocles, Ibsen, Shaw, Moli\u{00E8}re, and Chekhov."
        case "lv-travel":
            return "Journals of exploration, travelogues, and voyage narratives from Verne, Bird, Muir, and Darwin."
        case "lv-ancient-world":
            return "The foundational texts of classical antiquity: epic, drama, history, and philosophy from Greece and Rome."
        case "lv-poetry":
            return "Verse from every tradition: the epics of Homer and Dante, the sonnets of Shakespeare, the Romantics, and the Moderns."
        case "lv-philosophy-mind":
            return "The major works of Western philosophy, from Plato and Aristotle through Kant, Nietzsche, and the existentialists."
        case "lv-history":
            return "Narrative histories, chronicles, and biographies covering antiquity, the Middle Ages, and the modern era."
        case "lv-biography":
            return "The life stories of remarkable figures, told by themselves or by contemporaries, from Franklin to Keller."
        case "lv-science-nature":
            return "The classic works that shaped our understanding of the natural world: Darwin, Faraday, Newton, and more."
        case "lv-religion":
            return "Sacred texts, theological treatises, spiritual autobiographies, and devotional literature from many traditions."
        case "lv-essays-ideas":
            return "The essay as a literary form: reflections on politics, art, and culture by Montaigne, Emerson, Chesterton, and Thoreau."
        default:
            return "LibriVox public-domain audiobooks."
        }
    }

    private static func collectionDescription(for categoryID: String) -> String {
        switch categoryID {
        case "lv-general-fiction":
            return """
                General Fiction gathers the great novels and stories of the 18th and 19th centuries that do not fit neatly into a single genre label. Here you will find the social comedies of Jane Austen, the sprawling social panoramas of Charles Dickens, the domestic dramas of Elizabeth Gaskell and the Bront\u{00EB}s, the historical adventures of Sir Walter Scott, and the psychological realism of George Eliot and Thomas Hardy.

                LibriVox volunteers have recorded many of these works in multiple translations and versions. The enduring popularity of this category reflects the depth of the public-domain novel \u{2014} hundreds of hours of immersive storytelling, free for anyone to download.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-science-fiction":
            return """
                Long before blockbuster films and CGI, science fiction was a literary movement that asked what the future might hold. This collection spans the genre\u{2019}s formative decades: the scientific romances of H. G. Wells (\u{201c}The War of the Worlds,\u{201d} \u{201c}The Time Machine\u{201d}), the extraordinary voyages of Jules Verne, the pulp adventures of Edgar Rice Burroughs, and the space operas of E. E. \u{201c}Doc\u{201d} Smith.

                LibriVox volunteers have embraced science fiction enthusiastically. Many early 20th-century works that appeared in the pulp magazines of the 1920s through 1950s are now in the public domain and available as complete audiobooks. Whether you prefer philosophical speculation or interplanetary adventure, this category has hundreds of hours of listening.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-horror-gothic":
            return """
                From the candlelit corridors of Gothic castles to the cosmic dread of 20th-century New England, this collection traces two centuries of literary fear. It begins with the Gothic tradition \u{2014} the crumbling abbeys of Ann Radcliffe, the doomed scientist of Mary Shelley\u{2019}s \u{201c}Frankenstein,\u{201d} the epistolary vampire of Bram Stoker\u{2019}s \u{201c}Dracula,\u{201d} and the psychological doubles of Robert Louis Stevenson\u{2019}s \u{201c}Strange Case of Dr Jekyll and Mr Hyde.\u{201d}

                The American strain is equally well-represented: Edgar Allan Poe\u{2019}s tales of the grotesque and arabesque, the New England hauntings of H. P. Lovecraft and the Cthulhu mythos, and the quiet terrors of Algernon Blackwood and M. R. James. The genre\u{2019}s pioneers are all here, in recordings contributed by LibriVox volunteers and preserved at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-mystery-crime":
            return """
                The detective story is one of the most popular literary inventions of the modern era, and this collection gathers its earliest and most influential examples. Arthur Conan Doyle\u{2019}s Sherlock Holmes dominates the catalog \u{2014} all four novels and all five short-story collections are available in multiple LibriVox recordings \u{2014} but the genre extends far beyond Baker Street.

                Wilkie Collins pioneered the sensation novel with \u{201c}The Woman in White\u{201d} and \u{201c}The Moonstone.\u{201d} G. K. Chesterton\u{2019}s Father Brown brought theological insight to criminal investigation. Anna Katharine Green created the first American series detective. Edgar Wallace and R. Austin Freeman refined the puzzle-plot. And the true-crime tradition, from the Newgate Calendar to Victorian murder broadsides, is richly represented.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-adventure":
            return """
                Shipwrecks, buried treasure, musketeers, pirates, and pioneers: Adventure Fiction is the literature of the open road and the uncharted sea. It gathers the swashbuckling historical novels of Alexandre Dumas (\u{201c}The Three Musketeers,\u{201d} \u{201c}The Count of Monte Cristo\u{201d}), the boys\u{2019}-own adventures of G. A. Henty and R. M. Ballantyne, the frontier tales of James Fenimore Cooper and Zane Grey, and the sea stories of Herman Melville and Joseph Conrad.

                Mark Twain\u{2019}s Mississippi epics, Robert Louis Stevenson\u{2019}s treasure hunts, Jules Verne\u{2019}s incredible journeys, and more than a century\u{2019}s worth of thrilling, serialized fiction make this one of the deepest categories in the LibriVox collection.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-fantasy-mythology":
            return """
                Before Tolkien and modern epic fantasy, the Victorians and Edwardians built a rich tradition of fairy tales, children\u{2019}s fantasy, and mythological retellings. This collection brings together the nonsense worlds of Lewis Carroll, the American fairylands of L. Frank Baum (\u{201c}The Wonderful Wizard of Oz\u{201d} and its sequels), and the literary fairy tales of Hans Christian Andersen and Oscar Wilde.

                The mythological shelf is equally rich: classical mythology retold by Thomas Bulfinch and H. A. Guerber, the Norse sagas and the \u{201c}Prose Edda,\u{201d} and Andrew Lang\u{2019}s multicolored fairy books. The Brothers Grimm, Madame d\u{2019}Aulnoy, Charles Perrault, and James Stephens all contributed to a body of work that remains as enchanting today as when it was first published.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-romance":
            return """
                Romance in its 19th-century sense meant more than love stories \u{2014} it encompassed the sweeping historical novel, the comedy of manners, the Gothic passion-play, and the psychological drama of intimate relationships. Jane Austen\u{2019}s six novels anchor this collection with their razor-sharp social observation and timeless wit.

                The Bront\u{00EB} sisters contribute the passionate landscapes of \u{201c}Wuthering Heights\u{201d} and the quiet strength of \u{201c}Jane Eyre.\u{201d} Victor Hugo\u{2019}s \u{201c}Les Mis\u{00E9}rables\u{201d} and Alexandre Dumas\u{2019}s romantic adventures expand the category into French epic. The American strain runs through the sentimental novels of Louisa May Alcott and the historical romances of Winston Churchill (the novelist, not the statesman).

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-satire-humor":
            return """
                Laughter is universal, but great comic writing is a rare art. This collection gathers two millennia of literary humor \u{2014} from the biting verse satires of Juvenal and Horace, through the philosophical mock-essays of Jonathan Swift (\u{201c}A Modest Proposal,\u{201d} \u{201c}Gulliver\u{2019}s Travels\u{201d}), the urbane wit of Jane Austen, the deadpan absurdity of Mark Twain, the Wodehousian farce of Jeeves and Wooster, and the gentle absurdism of Jerome K. Jerome\u{2019}s \u{201c}Three Men in a Boat.\u{201d}

                Voltaire\u{2019}s \u{201c}Candide\u{201d} skewers philosophical optimism, while the essays of Charles Lamb, Max Beerbohm, and Stephen Leacock extend the tradition into the 20th century. LibriVox volunteers have recorded hundreds of humorous works, from full-length comic novels to short satirical sketches.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-war-military":
            return """
                War literature spans the spectrum from strategic theory to the soldier\u{2019}s-eye view of the battlefield. This collection opens with the foundational treatises on strategy: Sun Tzu\u{2019}s \u{201c}The Art of War,\u{201d} Carl von Clausewitz\u{2019}s \u{201c}On War,\u{201d} and Julius Caesar\u{2019}s \u{201c}Commentaries on the Gallic War.\u{201d}

                The narrative side includes Stephen Crane\u{2019}s impressionistic \u{201c}The Red Badge of Courage,\u{201d} Leo Tolstoy\u{2019}s monumental \u{201c}War and Peace,\u{201d} and the American Civil War memoirs of Ulysses S. Grant and William Tecumseh Sherman. Personal accounts from World War I \u{2014} including works by Siegfried Sassoon, Robert Graves, and Edith Wharton \u{2014} round out a collection that records both the grand strategy and the human cost of armed conflict.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-short-stories":
            return """
                The short story is one of the great literary art forms of the modern era, and it finds a natural home in audio. This collection brings together masters of the form from every tradition: the chilling tales of Edgar Allan Poe, the Chekhovian snapshots of ordinary life transformed, the twist endings of O. Henry, the sophisticated horror of Saki (H. H. Munro), and the psychological precision of Henry James and Edith Wharton.

                The LibriVox community also produces regular Short Story Collections \u{2014} themed anthologies of stories contributed by multiple readers \u{2014} which make it possible to sample dozens of authors in a single volume. Guy de Maupassant, W. W. Jacobs, Katherine Mansfield, F. Scott Fitzgerald, and hundreds of other writers are represented across the catalog.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-drama-plays":
            return """
                The great plays of the Western stage have been recorded by LibriVox volunteers in multiple formats: solo readings, dramatic collaborative projects where each character is read by a different volunteer, and full-cast productions with sound effects and music. This collection spans from the tragedies of ancient Athens to the drawing-room comedies of the Edwardian era.

                William Shakespeare dominates the catalog \u{2014} all 37 plays have been recorded, many in multiple versions \u{2014} but the collection also features the Greek tragedians (Aeschylus, Sophocles, Euripides), the comedies of Aristophanes, the French neo-classicists (Moli\u{00E8}re, Racine, Corneille), the Restoration comedies of Congreve and Sheridan, the social dramas of Ibsen and Shaw, the Chekhovian \u{201c}theatre of mood,\u{201d} and the satirical operettas of W. S. Gilbert.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-travel":
            return """
                Before mass tourism and Google Earth, intrepid travelers brought the world to readers through letters, journals, and published accounts. This collection gathers that literature of exploration: Isabella Bird\u{2019}s solo journeys through the Rocky Mountains and East Asia, John Muir\u{2019}s rapturous descriptions of the Sierra Nevada, Charles Darwin\u{2019}s \u{201c}Voyage of the Beagle,\u{201d} and the grand tours of Mark Twain (\u{201c}The Innocents Abroad,\u{201d} \u{201c}Roughing It\u{201d}).

                Fictional travel adventures are equally represented: Jules Verne\u{2019}s \u{201c}Around the World in Eighty Days,\u{201d} the shipwreck saga of \u{201c}The Swiss Family Robinson,\u{201d} and the fantastic voyages of Jonathan Swift and Ludvig Holberg. Whether armchair exploration or practical history, the category rewards browsing.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-ancient-world":
            return """
                The literature of classical antiquity is the root system of the Western tradition. This collection gathers the major works of Greek and Roman civilization as recorded by LibriVox volunteers: the epic poetry of Homer (\u{201c}The Iliad,\u{201d} \u{201c}The Odyssey\u{201d}) and Virgil (\u{201c}The Aeneid\u{201d}); the lyric verse of Sappho, Pindar, and Catullus; the histories of Herodotus, Thucydides, Xenophon, Livy, and Tacitus; and the philosophical dialogues and treatises of Plato, Aristotle, Epictetus, Marcus Aurelius, Lucretius, and Cicero.

                The Greek tragedians \u{2014} Aeschylus, Sophocles, and Euripides \u{2014} are represented through multiple translations and collaborative dramatic readings. Plutarch\u{2019}s parallel lives of noble Greeks and Romans offer the most comprehensive portrait of the classical world\u{2019}s leading figures.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-poetry":
            return """
                Poetry was meant to be heard before it was meant to be read, and LibriVox\u{2019}s poetry collection restores that oral tradition. Volunteers have recorded thousands of poems, from the great narrative epics \u{2014} Homer\u{2019}s \u{201c}Iliad\u{201d} and \u{201c}Odyssey,\u{201d} Virgil\u{2019}s \u{201c}Aeneid,\u{201d} Dante\u{2019}s \u{201c}Divine Comedy,\u{201d} Milton\u{2019}s \u{201c}Paradise Lost\u{201d} \u{2014} to the concentrated lyric intensities of Shakespeare\u{2019}s sonnets, Keats\u{2019}s odes, and Dickinson\u{2019}s compressed meditations.

                The Romantic poets \u{2014} Wordsworth, Coleridge, Byron, Shelley, Keats, Blake \u{2014} sit alongside the Victorians (Tennyson, Browning, Arnold, the Rossettis) and the Americans (Whitman, Dickinson, Poe, Longfellow). Weekly and fortnightly poetry projects mean new verse is continually added, making this one of the most active categories in the catalog.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-philosophy-mind":
            return """
                This collection surveys 2,500 years of systematic thought about knowledge, reality, ethics, and the mind. From the Socratic dialogues of Plato and the systematic treatises of Aristotle, through the medieval syntheses of Augustine and Aquinas, the rationalists (Descartes, Spinoza, Leibniz) and empiricists (Locke, Berkeley, Hume), the critical philosophy of Kant and post-Kantian German idealism (Hegel, Schopenhauer), to the existentialists (Kierkegaard, Nietzsche) and the early phenomenologists, the philosophical tradition is exceptionally well-represented in the LibriVox catalog.

                Eastern thought is present as well: the \u{201c}Analects\u{201d} of Confucius, the \u{201c}Tao Te Ching,\u{201d} the Upanishads, and the Buddhist sutras. Political philosophy from Machiavelli to Mill, the pragmatism of William James, and the early psychoanalytic writings of Freud round out a category that rewards both systematic study and casual browsing.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-history":
            return """
                From the first chroniclers of antiquity to the great narrative historians of the 19th century, this collection gathers the works that have shaped how we understand the past. The classical historians \u{2014} Herodotus, Thucydides, Xenophon, Livy, Tacitus, and Plutarch \u{2014} established the genre with their accounts of the Persian and Peloponnesian Wars, the rise and fall of Rome, and the lives of the great figures of antiquity.

                The Enlightenment and 19th century produced the monumental narrative histories that remain landmarks of English prose: Edward Gibbon\u{2019}s \u{201c}The History of the Decline and Fall of the Roman Empire,\u{201d} Thomas Macaulay\u{2019}s \u{201c}History of England,\u{201d} and John H. Haaren\u{2019}s early 20th-century survey texts. Specialist histories of the French Revolution, the American Civil War, and the First World War are abundantly available in LibriVox recordings.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-biography":
            return """
                Great lives, told well: this collection brings together autobiographies, memoirs, and contemporary biographies of the figures who have left their mark on history. The American strand is particularly strong \u{2014} Benjamin Franklin\u{2019}s autobiography, Frederick Douglass\u{2019}s searing slave narrative, Ulysses S. Grant\u{2019}s \u{201c}Personal Memoirs,\u{201d} and Helen Keller\u{2019}s \u{201c}The Story of My Life\u{201d} are all available in multiple LibriVox recordings.

                English biography is represented by James Boswell\u{2019}s \u{201c}The Life of Samuel Johnson\u{201d} (perhaps the greatest biography in the language), John Forster\u{2019}s \u{201c}Life of Charles Dickens,\u{201d} and the early 20th-century biographical series by Jacob Abbott and Elbert Hubbard. Memoirs of explorers, scientists, missionaries, and soldiers round out a category where the subject is always a remarkable human life.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-science-nature":
            return """
                The texts that built the modern scientific worldview are abundantly represented in the public domain \u{2014} and LibriVox volunteers have recorded them for anyone to hear. Charles Darwin\u{2019}s \u{201c}On the Origin of Species\u{201d} and \u{201c}The Descent of Man\u{201d} anchor the collection, alongside Alfred Russel Wallace\u{2019}s parallel evolutionary writings.

                The physical sciences are represented by Michael Faraday\u{2019}s \u{201c}The Chemical History of a Candle,\u{201d} Isaac Newton\u{2019}s \u{201c}Opticks,\u{201d} Galileo\u{2019}s \u{201c}Dialogue Concerning the Two Chief World Systems,\u{201d} and early 20th-century explanations of relativity and quantum theory. Natural history is dominated by the lyrical observations of John Muir, John Burroughs, and Jean-Henri Fabre. Mathematics and medicine round out a category that spans every field of human inquiry.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-religion":
            return """
                Sacred texts, theological reflections, and spiritual autobiographies from many of the world\u{2019}s great religious traditions. The Christian tradition is most extensively represented, with multiple recordings of the King James Bible (Old and New Testaments), Augustine\u{2019}s \u{201c}Confessions\u{201d} and \u{201c}City of God,\u{201d} Thomas Aquinas\u{2019}s \u{201c}Summa Theologica,\u{201d} John Calvin\u{2019}s \u{201c}Institutes of the Christian Religion,\u{201d} and the sermons of John Wesley, Charles Spurgeon, and Jonathan Edwards.

                Devotional classics \u{2014} Thomas \u{00E0} Kempis\u{2019}s \u{201c}The Imitation of Christ,\u{201d} John Bunyan\u{2019}s \u{201c}The Pilgrim\u{2019}s Progress,\u{201d} St. John of the Cross\u{2019}s \u{201c}Dark Night of the Soul\u{201d} \u{2014} sit alongside Eastern scriptures such as the Quran (in translation), the Bhagavad Gita, and Buddhist foundational texts. LibriVox volunteers come from many traditions, and the catalog reflects that diversity.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        case "lv-essays-ideas":
            return """
                The essay is the most personal form of non-fiction: a single mind working through a question in real time. This collection gathers the great essayists of the Western tradition: Michel de Montaigne, who invented the form and gave it its name; Francis Bacon, who stripped it to concentrated aphoristic power; Ralph Waldo Emerson, the prophet of American self-reliance; and Henry David Thoreau, whose \u{201c}Walden\u{201d} remains the essential American essay.

                The category also spans political and social thought \u{2014} the reflections of Edmund Burke on the French Revolution, John Ruskin on art and society, Thomas Carlyle on heroes and history \u{2014} and the early 20th-century critics and cultural commentators (G. K. Chesterton, H. L. Mencken, George Bernard Shaw) who made the essay a vehicle for wit, provocation, and moral seriousness.

                This collection draws on the LibriVox catalog hosted at [archive.org](https://archive.org/details/librivoxaudio).
                """
        default:
            return ""
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
        "Galileo Galilei", "William Harvey", "Miguel de Cervantes",
        "Francis Bacon", "René Descartes", "Baruch Spinoza", "John Milton",
        "Blaise Pascal", "Christiaan Huygens", "Isaac Newton", "John Locke",
        "George Berkeley", "David Hume", "Jonathan Swift", "Laurence Sterne",
        "Henry Fielding", "Montesquieu", "Jean-Jacques Rousseau", "Adam Smith",
        "Edward Gibbon", "Immanuel Kant", "Alexander Hamilton", "John Stuart Mill",
        "James Boswell", "Antoine Lavoisier", "Michael Faraday", "Georg Wilhelm Friedrich Hegel",
        "Johann Wolfgang von Goethe", "Herman Melville", "Charles Darwin", "Karl Marx",
        "Leo Tolstoy", "Fyodor Dostoevsky", "William James", "Sigmund Freud",
        "Johannes Kepler", "Henrik Ibsen", "Jane Austen", "Alexis de Tocqueville",
        "Joseph Conrad", "Anton Chekhov", "James Joyce", "Franz Kafka",
        "Albert Einstein", "Bertrand Russell", "Henri Poincaré",
        "Alfred North Whitehead", "Thorstein Veblen", "James George Frazer",
        "Henry James", "D. H. Lawrence"
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
