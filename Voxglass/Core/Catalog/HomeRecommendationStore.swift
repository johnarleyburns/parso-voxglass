import Combine
import Foundation

public struct RecommendationShelfSnapshot: Codable, Equatable, Sendable {
    public var results: [InternetArchiveSearchResult]
    public var source: RecommendationShelfSource
    public var savedAt: Date

    public init(results: [InternetArchiveSearchResult], source: RecommendationShelfSource, savedAt: Date) {
        self.results = results
        self.source = source
        self.savedAt = savedAt
    }
}

@MainActor
public final class HomeRecommendationStore: ObservableObject {
    public nonisolated static let shelfSnapshotKey = "guru.parso.voxglass.recommendationShelfSnapshot"

    @Published public private(set) var recommendations: [InternetArchiveSearchResult]
    @Published public private(set) var isRefreshing = false

    private let client: InternetArchiveCatalogClient
    private let defaults: UserDefaults
    private var engine: RecommendationEngine?
    private var engineReady = false
    private var visibleShelfSource: RecommendationShelfSource = .popularColdStart

    public init(
        client: InternetArchiveCatalogClient = InternetArchiveClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        if let snapshot = Self.loadSnapshot(from: defaults), !snapshot.results.isEmpty {
            self.recommendations = snapshot.results
            self.visibleShelfSource = snapshot.source
        } else {
            self.recommendations = Self.coldStartRecommendations(for: [])
        }
    }

    public func configure(profileStore: TasteProfileStore, libraryStore: LibraryStore) {
        engine = RecommendationEngine(
            client: client,
            profileStore: profileStore,
            libraryStore: libraryStore
        )
    }

    public func markEngineReady() {
        engineReady = true
    }

    public func load(selectedCollectionIDs: Set<String>, selectedLanguages: Set<String> = LibriVoxLanguage.defaultSelection) async {
        if recommendations.isEmpty {
            recommendations = Self.coldStartRecommendations(for: selectedCollectionIDs)
            visibleShelfSource = .popularColdStart
        }

        guard let engine, engineReady else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let shelf = await engine.fetchRecommendationShelf(
            selectedCollectionIDs: selectedCollectionIDs,
            selectedLanguages: selectedLanguages
        )
        guard !shelf.results.isEmpty else { return }

        if visibleShelfSource == .personalized,
           shelf.source != .personalized {
            return
        }

        recommendations = shelf.results
        visibleShelfSource = shelf.source
        if shelf.source == .personalized {
            Self.saveSnapshot(
                RecommendationShelfSnapshot(results: shelf.results, source: .personalized, savedAt: Date()),
                to: defaults
            )
        }
    }

    public nonisolated static func loadSnapshot(from defaults: UserDefaults) -> RecommendationShelfSnapshot? {
        guard let data = defaults.data(forKey: shelfSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(RecommendationShelfSnapshot.self, from: data)
    }

    public nonisolated static func saveSnapshot(_ snapshot: RecommendationShelfSnapshot, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: shelfSnapshotKey)
    }

    public nonisolated static func coldStartRecommendations(for _: Set<String>) -> [InternetArchiveSearchResult] {
        bundledPopularSeeds
    }

    public nonisolated static let bundledPopularSeeds: [InternetArchiveSearchResult] = [
        seed(identifier: "art_of_war_librivox", title: "The Art of War", creator: "Sun Tzu", downloads: 24_415739, date: "2006"),
        seed(identifier: "alice_in_wonderland_librivox", title: "Alice's Adventures in Wonderland, by Lewis Carroll", creator: "Lewis Carroll", downloads: 24_067020, date: "2006"),
        seed(identifier: "tom_sawyer_librivox", title: "The Adventures of Tom Sawyer", creator: "Mark Twain", downloads: 18_317587, date: "2006"),
        seed(identifier: "adventures_holmes", title: "The Adventures of Sherlock Holmes", creator: "Sir Arthur Conan Doyle", downloads: 17_636280, date: "2007"),
        seed(identifier: "moby_dick_librivox", title: "Moby Dick, or the Whale", creator: "Herman Melville", downloads: 12_463315, date: "2007"),
        seed(identifier: "huck_finn_librivox", title: "Adventures of Huckleberry Finn", creator: "Mark Twain", downloads: 11_580359, date: "2006"),
        seed(identifier: "pride_and_prejudice_librivox", title: "Pride and Prejudice", creator: "Jane Austen", downloads: 10_263319, date: "2006"),
        seed(identifier: "dracula_librivox", title: "Dracula", creator: "Bram Stoker", downloads: 9_545337, date: "2006"),
        seed(identifier: "adventures_sherlockholmes_1007_librivox", title: "The Adventures of Sherlock Holmes", creator: "Sir Arthur Conan Doyle", downloads: 8_742378, date: "2010"),
        seed(identifier: "count_monte_cristo_0711_librivox", title: "The Count of Monte Cristo", creator: "Alexandre Dumas", downloads: 7_901132, date: "2007"),
        seed(identifier: "pride_prejudice_krs_librivox", title: "Pride and Prejudice (version 3)", creator: "Jane Austen", downloads: 7_325292, date: "2007"),
        seed(identifier: "peter_pan_0707_librivox", title: "Peter Pan", creator: "J. M. Barrie", downloads: 6_842429, date: "2007"),
        seed(identifier: "secret_garden_librivox", title: "The Secret Garden", creator: "Frances Hodgson Burnett", downloads: 6_718538, date: "2006"),
        seed(identifier: "solo_pride_librivox", title: "Pride and Prejudice (version 2)", creator: "Jane Austen", downloads: 6_249030, date: "2006"),
        seed(identifier: "odyssey_butler_librivox", title: "The Odyssey", creator: "Homer", downloads: 6_101901, date: "2007"),
        seed(identifier: "grimms_english_librivox", title: "Grimms' Fairy Tales", creator: "Jacob and Wilhelm Grimm", downloads: 5_615276, date: "2006"),
        seed(identifier: "1891_collection_bt_librivox", title: "1891 Collection", creator: "Various", downloads: 5_517521, date: "2013"),
        seed(identifier: "prideandprejudice_1005_librivox", title: "Pride and Prejudice (version 4)", creator: "Jane Austen", downloads: 5_426264, date: "2010"),
        seed(identifier: "alices_adventures_1003", title: "Alice's Adventures in Wonderland", creator: "Lewis Carroll", downloads: 5_359128, date: "2010"),
        seed(identifier: "uncle_toms_cabin_librivox", title: "Uncle Tom's Cabin", creator: "Harriet Beecher Stowe", downloads: 5_097247, date: "2006"),
        seed(identifier: "tale_two_cities_librivox", title: "A Tale of Two Cities", creator: "Charles Dickens", downloads: 5_067943, date: "2006"),
        seed(identifier: "adventures_sherlock_holmes_rg_librivox", title: "The Adventures of Sherlock Holmes (Version 2)", creator: "Sir Arthur Conan Doyle", downloads: 5_063525, date: "2010"),
        seed(identifier: "adventures_pinocchio_librivox", title: "The Adventures of Pinocchio", creator: "C. Collodi", downloads: 4_942806, date: "2006"),
        seed(identifier: "treasure_island_ap_librivox", title: "Treasure Island", creator: "Robert Louis Stevenson", downloads: 4_928857, date: "2007"),
        seed(identifier: "emma_solo_librivox", title: "Emma", creator: "Jane Austen", downloads: 4_875850, date: "2006"),
        seed(identifier: "huckleberry_mfs_librivox", title: "Adventures of Huckleberry Finn (version 02)", creator: "Mark Twain", downloads: 4_825892, date: "2007"),
        seed(identifier: "memoirs_holmes_0709_librivox", title: "The Memoirs of Sherlock Holmes", creator: "Sir Arthur Conan Doyle", downloads: 4_810545, date: "2007"),
        seed(identifier: "aesop_fables_volume_one_librivox", title: "Aesop's Fables, Volume 1 (Fables 1-25)", creator: "Aesop", downloads: 4_728426, date: "2006"),
        seed(identifier: "andersensfairy_1307_librivox", title: "Andersen's Fairy Tales (Version 2)", creator: "Hans Christian Andersen", downloads: 4_702744, date: "2013"),
        seed(identifier: "jane_eyre_ver03_0809_librivox", title: "Jane Eyre (version 3)", creator: "Charlotte Brontë", downloads: 4_627380, date: "2008"),
        seed(identifier: "swiss_family_robinson_librivox", title: "The Swiss Family Robinson", creator: "Johann David Wyss", downloads: 4_314039, date: "2006"),
        seed(identifier: "andersens_fairytales_librivox", title: "Andersen's Fairy Tales", creator: "Hans Christian Andersen", downloads: 4_255577, date: "2006"),
        seed(identifier: "return_holmes_0708_librivox", title: "The Return of Sherlock Holmes", creator: "Sir Arthur Conan Doyle", downloads: 4_208367, date: "2007"),
        seed(identifier: "great_expectations_mfs_0812_librivox", title: "Great Expectations", creator: "Charles Dickens", downloads: 3_962102, date: "2008"),
        seed(identifier: "robinson_crusoe_librivox", title: "The Life and Strange Surprising Adventures of Robinson Crusoe of York, Mariner", creator: "Daniel Defoe", downloads: 3_961153, date: "2006"),
        seed(identifier: "game_of_life_0911_librivox", title: "The Game of Life and How to Play It", creator: "Florence Scovel Shinn", downloads: 3_862505, date: "2009"),
        seed(identifier: "bleak_house_cl_librivox", title: "Bleak House", creator: "Charles Dickens", downloads: 3_801954, date: "2008"),
        seed(identifier: "anthem_librivox", title: "Anthem", creator: "Ayn Rand", downloads: 3_784258, date: "2007"),
        seed(identifier: "romeo_and_juliet_librivox", title: "Romeo and Juliet", creator: "William Shakespeare", downloads: 3_661949, date: "2006"),
        seed(identifier: "anne_greengables_librivox", title: "Anne of Green Gables (version 3)", creator: "Lucy Maud Montgomery", downloads: 3_654302, date: "2007"),
        seed(identifier: "invisible_man_librivox", title: "The Invisible Man", creator: "H.G. Wells", downloads: 3_627712, date: "2006"),
        seed(identifier: "grimm_fairy_tales_1202_librivox", title: "Grimm's Fairy Tales (version 2)", creator: "Jacob & Wilhelm Grimm", downloads: 3_608157, date: "2012"),
        seed(identifier: "walden_librivox", title: "Walden", creator: "Henry David Thoreau", downloads: 3_577834, date: "2006"),
        seed(identifier: "timemachine_sjm_librivox", title: "The Time Machine (version 3)", creator: "H. G. Wells", downloads: 3_550415, date: "2011"),
        seed(identifier: "wizard_of_oz", title: "The Wonderful Wizard of Oz", creator: "L. Frank Baum", downloads: 3_517070, date: "2007"),
        seed(identifier: "jane_eyre_librivox", title: "Jane Eyre", creator: "Charlotte Brontë", downloads: 3_508740, date: "2007"),
        seed(identifier: "fabulas_esopo_01_librivox", title: "Las Fábulas de Esopo, vol. 01", creator: "Townsend, George Fyler; tr. Jorge R. Rodríguez", downloads: 3_450848, date: "2006"),
        seed(identifier: "english_fairy_tales_joy_librivox", title: "English Fairy Tales", creator: "Joseph Jacobs", downloads: 3_444360, date: "2007"),
        seed(identifier: "don_quijote_vol1_0706_librivox", title: "Don Quijote, Volume 1", creator: "Miguel de Cervantes Saavedra", downloads: 3_430939, date: "2007"),
        seed(identifier: "anne_of_green_gables_librivox", title: "Anne of Green Gables", creator: "Lucy Maud Montgomery", downloads: 3_413406, date: "2006"),
        seed(identifier: "penguin_island_ms_librivox", title: "Penguin Island", creator: "Anatole France", downloads: 3_367921, date: "2007"),
        seed(identifier: "beyond_good_and_evil_librivox", title: "Beyond Good and Evil", creator: "Friedrich Nietzsche (transl. Helen Zimmern)", downloads: 3_279705, date: "2006"),
        seed(identifier: "romeoandjuliet_ss_0901_librivox", title: "Romeo and Juliet", creator: "William Shakespeare", downloads: 3_275137, date: "2009"),
        seed(identifier: "1601_0903_librivox", title: "1601: Conversation, as it was by the Social Fireside, in the Time of the Tudors", creator: "Mark Twain", downloads: 3_214997, date: "2009"),
        seed(identifier: "railway_children_librivox", title: "Railway Children", creator: "E. Nesbit", downloads: 3_195271, date: "2006"),
        seed(identifier: "divine_comedy_librivox", title: "The Divine Comedy", creator: "Dante Alighieri", downloads: 3_123731, date: "2007"),
        seed(identifier: "letters_brides_0709_librivox", title: "Letters of Two Brides", creator: "Honore de Balzac", downloads: 3_115719, date: "2007"),
        seed(identifier: "heart_of_darkness", title: "Heart of Darkness", creator: "Joseph Conrad", downloads: 3_108867, date: "2006"),
        seed(identifier: "frankenstein_shelley", title: "Frankenstein", creator: "Mary W. Shelley", downloads: 3_108261, date: "2005"),
        seed(identifier: "adventuressherlockholmes_v4_1501_librivox", title: "The Adventures of Sherlock Holmes (version 4)", creator: "Sir Arthur Conan Doyle", downloads: 3_092898, date: "2015"),
        seed(identifier: "beowulf_te_librivox", title: "Beowulf", creator: "Unknown", downloads: 2_979406, date: "2013"),
        seed(identifier: "your_invisible_power_2104_librivox", title: "Your Invisible Power", creator: "Genevieve Behrend", downloads: 2_933396, date: "2012"),
        seed(identifier: "alexander_great_ld_librivox", title: "Alexander the Great", creator: "Jacob Abbott", downloads: 2_879200, date: "2007"),
        seed(identifier: "secret_garden_version2_librivox", title: "The Secret Garden", creator: "Frances Hodgson Burnett", downloads: 2_751338, date: "2009"),
        seed(identifier: "city_worlds_end_1203_librivox", title: "The City at World's End", creator: "Edmond Hamilton", downloads: 2_722259, date: "2012"),
        seed(identifier: "king_solomon_librivox", title: "King Solomon's Mines", creator: "H. Rider Haggard", downloads: 2_669172, date: "2006"),
        seed(identifier: "8thanniversary_1308_librivox", title: "LibriVox 8th Anniversary Collection", creator: "Various", downloads: 2_652821, date: "2013"),
        seed(identifier: "12_creepytales_1206_librivox", title: "12 Creepy Tales by Edgar Allan Poe", creator: "Edgar Allan Poe", downloads: 2_550915, date: "2012"),
        seed(identifier: "count_montecristo_1308_librivox", title: "The Count of Monte Cristo", creator: "Alexandre Dumas", downloads: 2_533258, date: "2013"),
        seed(identifier: "dracula_1006_librivox", title: "Dracula (version 2)", creator: "Bram Stoker", downloads: 2_526394, date: "2010"),
        seed(identifier: "terror_mystery_0707_librivox", title: "Tales of Terror and Mystery", creator: "Sir Arthur Conan Doyle", downloads: 2_526210, date: "2007"),
        seed(identifier: "ghost_stories_001_librivox", title: "Ghost Story Collection 001", creator: "Various", downloads: 2_515896, date: "2006"),
        seed(identifier: "beowulf", title: "Beowulf", creator: "Anonymous", downloads: 2_503961, date: "2006"),
        seed(identifier: "bequest_jg_librivox", title: "The $30,000 Bequest and Other Stories", creator: "Mark Twain", downloads: 2_493565, date: "2011"),
        seed(identifier: "love_freindship_cs_librivox", title: "Love and Freindship", creator: "Jane Austen", downloads: 2_472880, date: "2007"),
        seed(identifier: "call_of_the_wild", title: "The Call of the Wild", creator: "Jack London", downloads: 2_463160, date: "2005"),
        seed(identifier: "little_princess_krs", title: "A Little Princess", creator: "Frances Hodgson Burnett", downloads: 2_426321, date: "2007"),
        seed(identifier: "les_mis_vol01_0810_librivox", title: "Les Misérables, Vol. 1", creator: "Victor Hugo", downloads: 2_355745, date: "2008"),
        seed(identifier: "as_a_man_thinketh_mc_librivox", title: "As a Man Thinketh", creator: "James Allen", downloads: 2_324951, date: "2008"),
        seed(identifier: "prince_librivox", title: "The Prince", creator: "Nicolo Machiavelli; translated by W. K. Marriott", downloads: 2_294079, date: "2006"),
        seed(identifier: "reluctant_dragon_librivox", title: "The Reluctant Dragon", creator: "Kenneth Grahame", downloads: 2_237631, date: "2006"),
        seed(identifier: "2br02b_0801_librivox", title: "2 B R 0 2 B", creator: "Kurt Vonnegut", downloads: 2_223109, date: "2008"),
        seed(identifier: "fanny_hill_librivox", title: "Fanny Hill: Memoirs of a Woman of Pleasure", creator: "John Cleland", downloads: 2_220597, date: "2006"),
        seed(identifier: "amateur_cracksman_librivox", title: "The Amateur Cracksman", creator: "E.W. Hornung", downloads: 2_218127, date: "2006"),
        seed(identifier: "art_war_ps_librivox", title: "The Art of War", creator: "Sun Tzu", downloads: 2_199575, date: "2007"),
        seed(identifier: "sense_sensibility_ver3_ek", title: "Sense and Sensibility (Version 3)", creator: "Jane Austen", downloads: 2_173061, date: "2009"),
        seed(identifier: "aliceinwonderland_1102_librivox", title: "Alice's Adventures in Wonderland (dramatic reading)", creator: "Lewis Carroll", downloads: 2_142891, date: "2011"),
        seed(identifier: "mysterious_island_ms_librivox", title: "The Mysterious Island", creator: "Jules Verne", downloads: 2_081051, date: "2007"),
        seed(identifier: "american_indian_tales_librivox", title: "American Indian Fairy Tales", creator: "William Trowbridge Larned", downloads: 2_023228, date: "2006"),
        seed(identifier: "0_sense_and_sensibility_librivox", title: "Sense and Sensibility", creator: "Jane Austen", downloads: 2_010335, date: "2007"),
        seed(identifier: "franklin_autobio_gg_librivox", title: "The Autobiography of Benjamin Franklin", creator: "Benjamin Franklin, ed. Frank Woodworth Pine", downloads: 2_009096, date: "2007"),
        seed(identifier: "fabulas_esopo_02_librivox", title: "Las Fábulas de Esopo, vol. 02", creator: "Townsend, George Fyler; tr. Jorge R. Rodríguez", downloads: 1_996067, date: "2006"),
        seed(identifier: "gods_of_mars_librivox", title: "The Gods of Mars", creator: "Edgar Rice Burroughs", downloads: 1_974417, date: "2006"),
        seed(identifier: "science_gettingrich_1005_librivox", title: "The Science of Getting Rich", creator: "Wallace D. Wattles", downloads: 1_955966, date: "2010"),
        seed(identifier: "being_earnest_librivox", title: "The Importance of Being Earnest", creator: "Oscar Wilde", downloads: 1_942337, date: "2006"),
        seed(identifier: "war_worlds_solo_librivox", title: "War of the Worlds", creator: "H.G. Wells", downloads: 1_934877, date: "2006"),
        seed(identifier: "wuthering_heights_rg_librivox", title: "Wuthering Heights (Solo Version)", creator: "Emily Bronte", downloads: 1_934338, date: "2009"),
        seed(identifier: "alice_wonderland_0711_librivox", title: "Alice's Adventures in Wonderland", creator: "Lewis Carroll", downloads: 1_852365, date: "2007"),
        seed(identifier: "gulliver_ld_librivox", title: "Gulliver's Travels", creator: "Jonathan Swift", downloads: 1_842997, date: "2007"),
        seed(identifier: "girl_boat_1109_librivox", title: "The Girl on the Boat", creator: "P.G. Wodehouse", downloads: 1_832814, date: "2011"),
    ]

    public nonisolated static let bundledTasteSeeds: [InternetArchiveSearchResult] = [
        seed(identifier: "return_holmes_0708_librivox", title: "The Return of Sherlock Holmes", creator: "Arthur Conan Doyle", collections: ["librivoxaudio", "lv-mystery-crime"]),
        seed(identifier: "timemachine_sjm_librivox", title: "The Time Machine", creator: "H. G. Wells", collections: ["librivoxaudio", "lv-science-fiction"]),
        seed(identifier: "call_cthulhu_2401_librivox", title: "The Call of Cthulhu", creator: "H. P. Lovecraft", collections: ["librivoxaudio", "lv-horror-gothic"]),
        seed(identifier: "wuthering_heights_rg_librivox", title: "Wuthering Heights", creator: "Emily Bronte", collections: ["librivoxaudio", "lv-romance"]),
        seed(identifier: "decline_fall_1_0707_librivox", title: "The History of the Decline and Fall of the Roman Empire", creator: "Edward Gibbon", collections: ["librivoxaudio", "lv-history"]),
        seed(identifier: "republic_version_2_1310_librivox", title: "The Republic", creator: "Plato", collections: ["librivoxaudio", "lv-philosophy-mind"]),
        seed(identifier: "poems_every_child_should_know_librivox", title: "Poems Every Child Should Know", creator: "Various", collections: ["librivoxaudio", "lv-poetry"]),
        seed(identifier: "stories_006_librivox", title: "Short Story Collection", creator: "Various", collections: ["librivoxaudio", "lv-short-stories"]),
        seed(identifier: "franklin_autobio_gg_librivox", title: "The Autobiography of Benjamin Franklin", creator: "Benjamin Franklin", collections: ["librivoxaudio", "lv-biography"]),
        seed(identifier: "iliad_popetranslation_1506_librivox", title: "The Iliad", creator: "Homer", collections: ["librivoxaudio", "lv-general-fiction"])
    ]

    public nonisolated static func uniqueResults(_ results: [InternetArchiveSearchResult]) -> [InternetArchiveSearchResult] {
        var seen: Set<String> = []
        return results.filter { result in
            seen.insert(result.identifier).inserted
        }
    }

    nonisolated private static func seed(
        identifier: String,
        title: String,
        creator: String,
        description: String? = nil,
        collections: [String] = ["librivoxaudio"],
        downloads: Int? = nil,
        date: String? = nil
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: description,
            collections: collections,
            downloads: downloads,
            date: date
        )
    }
}
