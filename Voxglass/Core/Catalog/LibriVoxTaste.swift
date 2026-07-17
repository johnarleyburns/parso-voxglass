import Foundation

public struct LibriVoxTaste: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var archiveQuery: String

    public static let all: [LibriVoxTaste] = [
        LibriVoxTaste(
            id: "classics",
            title: "Classics",
            systemImage: "building.columns.fill",
            archiveQuery: LibriVoxCatalogScope.matching("subject:Classics OR subject:Literature OR subject:\"Classics (Greek & Latin Antiquity)\" OR subject:\"Literary Fiction\"")
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

    public static func taste(withID id: String) -> LibriVoxTaste? {
        all.first { $0.id == id }
    }

    public static func selected(from ids: Set<String>) -> [LibriVoxTaste] {
        all.filter { ids.contains($0.id) }
    }
}
