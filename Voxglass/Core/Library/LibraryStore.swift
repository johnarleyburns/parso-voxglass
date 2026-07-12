import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookWithChapters] = []
    @Published private(set) var sources: [Source] = []
    @Published private(set) var recentlyPlayed: [BookWithChapters] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    private let repository: LibraryRepository
    private let snapshotStore = LastPlaybackSnapshotStore()
    private weak var playback: PlaybackCoordinator?
    private weak var offlineManager: OfflineDownloadManager?

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    /// Wires up collaborators used by `delete(book:)`. Called by `AppServices`
    /// after all stores are constructed.
    func configure(playback: PlaybackCoordinator, offlineManager: OfflineDownloadManager) {
        self.playback = playback
        self.offlineManager = offlineManager
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

    /// Removes a book from the library and purges everything associated with it:
    /// in-flight offline downloads, pinned/passive cached audio + cover art,
    /// database rows (cascade), recently-viewed entry, and — if it is the current
    /// or last session — the active playback and its restore snapshot.
    func delete(book: BookWithChapters) async {
        let bookID = book.book.id

        // 1. Cancel any in-flight offline downloads, unpin + drop their records.
        await offlineManager?.removeOffline(book: book)

        // 2. Purge cache: every chapter's audio (remote + opus) and the cover art.
        var keys: [String] = []
        for chapter in book.chapters {
            if let remoteURL = chapter.remoteURL {
                keys.append(CachingResourceLoader.key(for: remoteURL))
            }
            if let opusURL = chapter.opusURL {
                keys.append(CachingResourceLoader.key(for: opusURL))
            }
        }
        if let coverURL = book.book.coverURL {
            keys.append(ArtworkService.cacheKey(for: coverURL))
        }
        if !keys.isEmpty {
            await StreamCacheStore.shared.remove(keys: keys)
        }

        // 3. Delete the book (cascades chapters, positions, bookmarks, etc.) and
        //    its orphaned source.
        do {
            try await repository.deleteBook(bookID)
        } catch {
            importError = error.localizedDescription
            return
        }

        // 4. Update in-memory collections.
        books.removeAll { $0.book.id == bookID }
        recentlyPlayed.removeAll { $0.book.id == bookID }
        sources = (try? await repository.fetchSources()) ?? sources

        // 5. Drop the recently-viewed entry.
        let key = RecentlyViewedBooksStore.key
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        UserDefaults.standard.set(RecentlyViewedBooksStore.removing(bookID: bookID, in: raw), forKey: key)

        // 6. Stop playback / clear the restore snapshot if this was the live or
        //    last session.
        if snapshotStore.load()?.bookID == bookID {
            snapshotStore.clear()
        }
        playback?.stopPlayback(forDeletedBook: bookID)
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
