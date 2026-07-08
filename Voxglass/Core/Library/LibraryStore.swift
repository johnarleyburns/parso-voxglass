import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookWithChapters] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    private let repository: LibraryRepository

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    func refresh() async {
        do {
            books = try await repository.fetchLibrary()
        } catch {
            importError = error.localizedDescription
        }
    }

    func importLocalAudio(from urls: [URL]) async -> [BookWithChapters] {
        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try await repository.importLocalAudio(from: urls)
            await refresh()
            return imported
        } catch {
            importError = error.localizedDescription
            return []
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
}
