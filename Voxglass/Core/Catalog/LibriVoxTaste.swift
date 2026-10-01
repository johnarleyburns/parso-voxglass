import Foundation

public struct LibriVoxTaste: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var archiveQuery: String

    public static let all: [LibriVoxTaste] = [
        LibriVoxTaste(
            id: "classics",
            title: String(localized: "Classics", bundle: .module),
            systemImage: "building.columns.fill",
            archiveQuery: LibriVoxCatalogScope.matching("subject:Classics OR subject:Literature OR subject:\"Classics (Greek & Latin Antiquity)\"")
        ),
        LibriVoxTaste(
            id: "mystery",
            title: String(localized: "Mystery", bundle: .module),
            systemImage: "magnifyingglass",
            archiveQuery: LibriVoxBrowseCategory.mysteryCrime.archiveQuery
        ),
        LibriVoxTaste(
            id: "sci-fi",
            title: String(localized: "Sci-Fi", bundle: .module),
            systemImage: "sparkles",
            archiveQuery: LibriVoxBrowseCategory.scienceFiction.archiveQuery
        ),
        LibriVoxTaste(
            id: "horror",
            title: String(localized: "Horror", bundle: .module),
            systemImage: "moon.stars.fill",
            archiveQuery: LibriVoxBrowseCategory.horrorGothic.archiveQuery
        ),
        LibriVoxTaste(
            id: "romance",
            title: String(localized: "Romance", bundle: .module),
            systemImage: "heart.fill",
            archiveQuery: LibriVoxBrowseCategory.romance.archiveQuery
        ),
        LibriVoxTaste(
            id: "history",
            title: String(localized: "History", bundle: .module),
            systemImage: "clock.arrow.circlepath",
            archiveQuery: LibriVoxBrowseCategory.history.archiveQuery
        ),
        LibriVoxTaste(
            id: "philosophy",
            title: String(localized: "Philosophy", bundle: .module),
            systemImage: "brain.head.profile",
            archiveQuery: LibriVoxBrowseCategory.philosophyMind.archiveQuery
        ),
        LibriVoxTaste(
            id: "poetry",
            title: String(localized: "Poetry", bundle: .module),
            systemImage: "quote.bubble.fill",
            archiveQuery: LibriVoxBrowseCategory.poetry.archiveQuery
        ),
        LibriVoxTaste(
            id: "short-stories",
            title: String(localized: "Short Stories", bundle: .module),
            systemImage: "text.book.closed",
            archiveQuery: LibriVoxBrowseCategory.shortStories.archiveQuery
        ),
        LibriVoxTaste(
            id: "biography",
            title: String(localized: "Biography", bundle: .module),
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
