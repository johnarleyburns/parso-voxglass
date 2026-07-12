import Foundation

struct LibriVoxTaste: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var archiveQuery: String

    static let all: [LibriVoxTaste] = [
        LibriVoxTaste(
            id: "classics",
            title: "Classics",
            systemImage: "building.columns.fill",
            archiveQuery: "collection:librivoxaudio AND (subject:Classics OR subject:Literature OR subject:\"Classics (Greek & Latin Antiquity)\" OR subject:\"Literary Fiction\")"
        ),
        LibriVoxTaste(
            id: "mystery",
            title: "Mystery",
            systemImage: "magnifyingglass",
            archiveQuery: LibriVoxBrowseCategory.mysteryCrime.archiveQuery
        ),
        LibriVoxTaste(
            id: "sci-fi",
            title: "Sci-Fi",
            systemImage: "sparkles",
            archiveQuery: LibriVoxBrowseCategory.scienceFiction.archiveQuery
        ),
        LibriVoxTaste(
            id: "horror",
            title: "Horror",
            systemImage: "moon.stars.fill",
            archiveQuery: LibriVoxBrowseCategory.horrorGothic.archiveQuery
        ),
        LibriVoxTaste(
            id: "romance",
            title: "Romance",
            systemImage: "heart.fill",
            archiveQuery: LibriVoxBrowseCategory.romance.archiveQuery
        ),
        LibriVoxTaste(
            id: "history",
            title: "History",
            systemImage: "clock.arrow.circlepath",
            archiveQuery: LibriVoxBrowseCategory.history.archiveQuery
        ),
        LibriVoxTaste(
            id: "philosophy",
            title: "Philosophy",
            systemImage: "brain.head.profile",
            archiveQuery: LibriVoxBrowseCategory.philosophyMind.archiveQuery
        ),
        LibriVoxTaste(
            id: "poetry",
            title: "Poetry",
            systemImage: "quote.bubble.fill",
            archiveQuery: LibriVoxBrowseCategory.poetry.archiveQuery
        ),
        LibriVoxTaste(
            id: "short-stories",
            title: "Short Stories",
            systemImage: "text.book.closed",
            archiveQuery: LibriVoxBrowseCategory.shortStories.archiveQuery
        ),
        LibriVoxTaste(
            id: "biography",
            title: "Biography",
            systemImage: "person.text.rectangle",
            archiveQuery: LibriVoxBrowseCategory.biography.archiveQuery
        )
    ]

    static func taste(withID id: String) -> LibriVoxTaste? {
        all.first { $0.id == id }
    }

    static func selected(from ids: Set<String>) -> [LibriVoxTaste] {
        all.filter { ids.contains($0.id) }
    }
}

enum LibriVoxRecommendationQueryBuilder {
    static func queries(for selectedIDs: Set<String>) -> [String] {
        let browseQueryMap = Dictionary(uniqueKeysWithValues:
            LibriVoxBrowseGroup.categories.map { ($0.id, $0.archiveQuery) })
        let curatedQueryMap: [String: String] = [
            "great-books": CuratedQueries.greatBooks,
            "greater-books": CuratedQueries.greaterBooks,
            "ancient-greece": CuratedQueries.ancientGreece
        ]
        let tasteQueryMap = Dictionary(uniqueKeysWithValues:
            LibriVoxTaste.all.map { ($0.id, $0.archiveQuery) })

        let all = browseQueryMap
            .merging(curatedQueryMap) { $1 }
            .merging(tasteQueryMap) { $1 }

        let selected = selectedIDs.compactMap { all[$0] }
        return selected.isEmpty ? [LibriVoxBrowseCategory.popular.archiveQuery] : selected
    }
}
