import Combine
import Foundation

@MainActor
final class HomeRecommendationStore: ObservableObject {
    @Published private(set) var recommendations: [InternetArchiveSearchResult]
    @Published private(set) var isRefreshing = false

    private let client: InternetArchiveCatalogClient

    init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
        self.recommendations = Self.coldStartRecommendations(for: [])
    }

    func load(selectedTasteIDs: Set<String>) async {
        recommendations = Self.coldStartRecommendations(for: selectedTasteIDs)

        let queries = LibriVoxRecommendationQueryBuilder.queries(for: selectedTasteIDs)
        guard !queries.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var refreshed: [InternetArchiveSearchResult] = []
        for query in queries.prefix(4) {
            do {
                let results = try await client.searchAdvanced(query: query, rows: 10)
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

    nonisolated static func coldStartRecommendations(for selectedTasteIDs: Set<String>) -> [InternetArchiveSearchResult] {
        let selected = LibriVoxTaste.selected(from: selectedTasteIDs)
        guard !selected.isEmpty else {
            return bundledPopularSeeds
        }

        let matching = bundledTasteSeeds.filter { result in
            selected.contains { taste in
                result.collections.contains(taste.id) || result.title.localizedCaseInsensitiveContains(taste.title)
            }
        }
        return matching.isEmpty ? bundledPopularSeeds : uniqueResults(matching + bundledPopularSeeds)
    }

    nonisolated static let bundledPopularSeeds: [InternetArchiveSearchResult] = [
        seed(
            identifier: "pride_and_prejudice_librivox",
            title: "Pride and Prejudice",
            creator: "Jane Austen",
            description: "A sharp comedy of manners and one of LibriVox's perennial favorites.",
            downloads: 1_200_000,
            date: "1813"
        ),
        seed(
            identifier: "adventuresofsherlockholmes_1110_librivox",
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
            identifier: "frankenstein_1818_librivox",
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
            identifier: "war_and_peace_librivox",
            title: "War and Peace",
            creator: "Leo Tolstoy",
            description: "Tolstoy's vast novel of family, war, and Russian society.",
            downloads: 640_000,
            date: "1869"
        )
    ]

    nonisolated static let bundledTasteSeeds: [InternetArchiveSearchResult] = [
        seed(identifier: "return_of_sherlock_holmes_librivox", title: "The Return of Sherlock Holmes", creator: "Arthur Conan Doyle", collections: ["librivoxaudio", "mystery"]),
        seed(identifier: "time_machine_librivox", title: "The Time Machine", creator: "H. G. Wells", collections: ["librivoxaudio", "sci-fi"]),
        seed(identifier: "call_of_cthulhu_librivox", title: "The Call of Cthulhu", creator: "H. P. Lovecraft", collections: ["librivoxaudio", "horror"]),
        seed(identifier: "wuthering_heights_librivox", title: "Wuthering Heights", creator: "Emily Bronte", collections: ["librivoxaudio", "romance"]),
        seed(identifier: "history_of_the_decline_and_fall_01_librivox", title: "The History of the Decline and Fall of the Roman Empire", creator: "Edward Gibbon", collections: ["librivoxaudio", "history"]),
        seed(identifier: "republic_librivox", title: "The Republic", creator: "Plato", collections: ["librivoxaudio", "philosophy"]),
        seed(identifier: "poems_every_child_should_know_librivox", title: "Poems Every Child Should Know", creator: "Various", collections: ["librivoxaudio", "poetry"]),
        seed(identifier: "shortstorycollection001_librivox", title: "Short Story Collection", creator: "Various", collections: ["librivoxaudio", "short-stories"]),
        seed(identifier: "autobiography_benjamin_franklin_librivox", title: "The Autobiography of Benjamin Franklin", creator: "Benjamin Franklin", collections: ["librivoxaudio", "biography"]),
        seed(identifier: "iliad_librivox", title: "The Iliad", creator: "Homer", collections: ["librivoxaudio", "classics"])
    ]

    nonisolated static func uniqueResults(_ results: [InternetArchiveSearchResult]) -> [InternetArchiveSearchResult] {
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
