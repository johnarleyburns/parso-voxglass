import Combine
import Foundation

@MainActor
public final class HomeRecommendationStore: ObservableObject {
    @Published public private(set) var recommendations: [InternetArchiveSearchResult]
    @Published public private(set) var isRefreshing = false

    private let client: InternetArchiveCatalogClient
    private var engine: RecommendationEngine?

    public init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
        self.recommendations = Self.coldStartRecommendations(for: [])
    }

    public func configure(profileStore: TasteProfileStore, libraryStore: LibraryStore) {
        engine = RecommendationEngine(
            client: client,
            profileStore: profileStore,
            libraryStore: libraryStore
        )
    }

    public func load(selectedCollectionIDs: Set<String>, selectedLanguages: Set<String> = LibriVoxLanguage.defaultSelection) async {
        if recommendations.isEmpty {
            recommendations = Self.coldStartRecommendations(for: selectedCollectionIDs)
        }

        if let engine {
            isRefreshing = true
            defer { isRefreshing = false }

            let recs = await engine.fetchRecommendations(
                selectedCollectionIDs: selectedCollectionIDs,
                selectedLanguages: selectedLanguages
            )
            if !recs.isEmpty {
                recommendations = recs
            }
            return
        }

        let coldStart = Self.coldStartRecommendations(for: selectedCollectionIDs)
        if !coldStart.isEmpty {
            recommendations = coldStart
        }

        let queries = LibriVoxRecommendationQueryBuilder.queries(for: selectedCollectionIDs)
        guard !queries.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let languageClause = LibriVoxLanguage.clause(for: selectedLanguages)
        var refreshed: [InternetArchiveSearchResult] = []
        for query in queries.prefix(4) {
            do {
                let results = try await client.searchAdvanced(query: query + languageClause, rows: 10)
                refreshed.append(contentsOf: results)
            } catch {
                continue
            }
        }

        let unique = Self.uniqueResults(refreshed)
        if !unique.isEmpty {
            recommendations = Array(unique.prefix(18))
        }
    }

    public nonisolated static func coldStartRecommendations(for _: Set<String>) -> [InternetArchiveSearchResult] {
        bundledPopularSeeds
    }

    public nonisolated static let bundledPopularSeeds: [InternetArchiveSearchResult] = [
        seed(
            identifier: "pride_and_prejudice_librivox",
            title: "Pride and Prejudice",
            creator: "Jane Austen",
            description: "A sharp comedy of manners and one of LibriVox's perennial favorites.",
            downloads: 1_200_000,
            date: "1813"
        ),
        seed(
            identifier: "adventures_sherlockholmes_1007_librivox",
            title: "The Adventures of Sherlock Holmes",
            creator: "Arthur Conan Doyle",
            description: "Classic detective stories featuring Holmes and Watson.",
            downloads: 980_000,
            date: "1892"
        ),
        seed(
            identifier: "alice_in_wonderland_librivox",
            title: "Alice's Adventures in Wonderland",
            creator: "Lewis Carroll",
            description: "A playful fantasy journey through Wonderland.",
            downloads: 920_000,
            date: "1865"
        ),
        seed(
            identifier: "frankenstein_cs_librivox",
            title: "Frankenstein",
            creator: "Mary Wollstonecraft Shelley",
            description: "The Gothic novel that helped define science fiction.",
            downloads: 870_000,
            date: "1818"
        ),
        seed(
            identifier: "dracula_librivox",
            title: "Dracula",
            creator: "Bram Stoker",
            description: "The vampire classic in public-domain audio.",
            downloads: 810_000,
            date: "1897"
        ),
        seed(
            identifier: "jane_eyre_librivox",
            title: "Jane Eyre",
            creator: "Charlotte Bronte",
            description: "A landmark Gothic romance and coming-of-age novel.",
            downloads: 760_000,
            date: "1847"
        ),
        seed(
            identifier: "moby_dick_librivox",
            title: "Moby Dick",
            creator: "Herman Melville",
            description: "Melville's sea epic about obsession and pursuit.",
            downloads: 690_000,
            date: "1851"
        ),
        seed(
            identifier: "war_and_peace_vol1_dole_mas_librivox",
            title: "War and Peace",
            creator: "Leo Tolstoy",
            description: "Tolstoy's vast novel of family, war, and Russian society.",
            downloads: 640_000,
            date: "1869"
        )
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
