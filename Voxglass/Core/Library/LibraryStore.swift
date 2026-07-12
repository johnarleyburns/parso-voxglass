import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookWithChapters] = []
    @Published private(set) var sources: [Source] = []
    @Published private(set) var recentlyPlayed: [BookWithChapters] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    private let repository: LibraryRepository

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    func refresh() async {
        do {
            books = try await repository.fetchLibrary()
            sources = try await repository.fetchSources()
            recentlyPlayed = try await repository.fetchRecentlyPlayed()
        } catch {
            importError = error.localizedDescription
        }
    }

    func refreshRecentlyPlayed() async {
        do {
            recentlyPlayed = try await repository.fetchRecentlyPlayed()
        } catch {
            importError = error.localizedDescription
        }
    }

    func books(filteredBy filter: LibraryBookFilter) async -> [BookWithChapters] {
        do {
            return try await repository.fetchBooks(filteredBy: filter)
        } catch {
            importError = error.localizedDescription
            return []
        }
    }

    func setFavorite(_ isFavorite: Bool, for bookID: UUID) async {
        do {
            guard let updatedBook = try await repository.setFavorite(isFavorite, for: bookID) else {
                return
            }
            replace(updatedBook)
            recentlyPlayed = recentlyPlayed.map { $0.book.id == bookID ? updatedBook : $0 }
        } catch {
            importError = error.localizedDescription
        }
    }

    func importInternetArchiveItem(
        _ metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async -> BookWithChapters? {
        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try await repository.importInternetArchiveItem(metadata, sourceKind: sourceKind)
            await refresh()
            return imported
        } catch {
            importError = error.localizedDescription
            return nil
        }
    }

    func book(containing chapterID: UUID) -> BookWithChapters? {
        books.first { book in
            book.chapters.contains { $0.id == chapterID }
        }
    }

    func book(withID bookID: UUID) -> BookWithChapters? {
        books.first { $0.book.id == bookID }
    }

    func source(for book: Book) -> Source? {
        sources.first { $0.id == book.sourceID }
    }

    var favoriteBooks: [BookWithChapters] {
        books.filter(\.book.isFavorite)
    }

    var authorNames: [String] {
        let names = books.flatMap(\.book.authors)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Unknown author" }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func books(byAuthor author: String) -> [BookWithChapters] {
        books.filter { book in
            book.book.authors.contains { $0.localizedCaseInsensitiveCompare(author) == .orderedSame }
        }
    }

    private func replace(_ updatedBook: BookWithChapters) {
        if let index = books.firstIndex(where: { $0.book.id == updatedBook.book.id }) {
            books[index] = updatedBook
        } else {
            books.insert(updatedBook, at: 0)
        }
    }
}
