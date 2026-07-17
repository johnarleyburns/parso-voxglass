import Foundation

@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var books: [BookWithChapters] = []
    @Published public private(set) var sources: [Source] = []
    @Published public private(set) var recentlyPlayed: [BookWithChapters] = []
    @Published public private(set) var isImporting = false
    @Published public var importError: String?

    /// P1-2: in-memory filter + sort. Changing these recomputes `visibleBooks`
    /// with zero DB round-trips.
    @Published public var filter: LibraryBookFilter = .all
    @Published public var sort: LibrarySort = .recent
    @Published public private(set) var progressByBook: [UUID: BookProgress] = [:]
    @Published public private(set) var listenedWorkExclusionKeys: Set<String> = []

    /// The library with the active filter/sort applied. Pure, in-memory.
    public var visibleBooks: [BookWithChapters] {
        var result = books

        switch filter {
        case .all: break
        case .favorites:
            result = result.filter(\.book.isFavorite)
        case .source(let sourceID):
            result = result.filter { $0.book.sourceID == sourceID }
        case .downloaded:
            // The UI layer already reads offlineManager.state(for:) — this is the DB variant for the repository path. Fall back: keep all.
            break
        case .finished:
            result = result.filter { progressByBook[$0.book.id]?.isFinished == true }
        case .inProgress:
            result = result.filter {
                guard let p = progressByBook[$0.book.id] else { return false }
                return !p.isFinished && p.lastPosition > 0
            }
        }

        result.sort(by: sort.comparator())
        return result
    }

    private let repository: LibraryRepository
    private let snapshotStore = LastPlaybackSnapshotStore()
    private weak var playback: PlaybackCoordinator?
    private weak var offlineManager: OfflineDownloadManager?

    /// Invoked after a book is imported so the cloud-sync layer can adopt any
    /// stored playback position for it (the delete-and-reinstall path, Phase 3).
    public var onBookImported: ((UUID) async -> Void)?

    public init(repository: LibraryRepository) {
        self.repository = repository
    }

    /// Wires up collaborators used by `delete(book:)`. Called by `AppServices`
    /// after all stores are constructed.
    public func configure(playback: PlaybackCoordinator, offlineManager: OfflineDownloadManager) {
        self.playback = playback
        self.offlineManager = offlineManager
    }

    public func refresh() async {
        do {
            books = try await repository.fetchLibrary()
            sources = try await repository.fetchSources()
            recentlyPlayed = try await repository.fetchRecentlyPlayed()
            progressByBook = try await repository.fetchBookProgress()
            listenedWorkExclusionKeys = try await repository.fetchListenedWorkExclusionKeys()
        } catch let fetchError {
            importError = fetchError.localizedDescription
        }
    }

    public func refreshRecentlyPlayed() async {
        do {
            recentlyPlayed = try await repository.fetchRecentlyPlayed()
            listenedWorkExclusionKeys = try await repository.fetchListenedWorkExclusionKeys()
        } catch {
            importError = error.localizedDescription
        }
    }

    @discardableResult
    public func refreshListenedWorkExclusionKeys() async -> Set<String> {
        do {
            listenedWorkExclusionKeys = try await repository.fetchListenedWorkExclusionKeys()
            return listenedWorkExclusionKeys
        } catch {
            importError = error.localizedDescription
            return listenedWorkExclusionKeys
        }
    }

    /// One-time best-effort pass over already-imported books whose narrators are
    /// empty: extract names from their stored summary and persist them. Refreshes
    /// the in-memory library if anything changed.
    public func backfillNarratorsIfNeeded() async {
        do {
            let updated = try await repository.backfillMissingNarrators()
            if updated > 0 {
                books = try await repository.fetchLibrary()
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    public func books(filteredBy filter: LibraryBookFilter) async -> [BookWithChapters] {
        do {
            return try await repository.fetchBooks(filteredBy: filter)
        } catch {
            importError = error.localizedDescription
            return []
        }
    }

    public func setFavorite(_ isFavorite: Bool, for bookID: UUID) async {
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

    public func importInternetArchiveItem(
        _ metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async -> BookWithChapters? {
        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try await repository.importInternetArchiveItem(metadata, sourceKind: sourceKind)
            await refresh()
            await onBookImported?(imported.book.id)
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
    public func delete(book: BookWithChapters) async {
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
            keys.append(ArtworkCacheKey.key(for: coverURL))
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
        snapshotStore.clear(bookID: bookID)
        playback?.stopPlayback(forDeletedBook: bookID)
    }

    public func book(containing chapterID: UUID) -> BookWithChapters? {
        books.first { book in
            book.chapters.contains { $0.id == chapterID }
        }
    }

    public func book(withID bookID: UUID) -> BookWithChapters? {
        books.first { $0.book.id == bookID }
    }

    /// The archive.org subjects stored for a book at import time (`book_taste`),
    /// used to map the book to a browse genre for the Now Playing screen.
    public func bookSubjects(for bookID: UUID) async -> [String] {
        guard let terms = try? await repository.fetchBookTasteTerms(for: bookID) else {
            return []
        }
        return terms.filter { $0.axis == "subject" }.map(\.term)
    }

    public func source(for book: Book) -> Source? {
        sources.first { $0.id == book.sourceID }
    }

    public var favoriteBooks: [BookWithChapters] {
        books.filter(\.book.isFavorite)
    }

    public var authorNames: [String] {
        let names = books.flatMap(\.book.authors)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Unknown author" }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func books(byAuthor author: String) -> [BookWithChapters] {
        books.filter { book in
            book.book.authors.contains { $0.localizedCaseInsensitiveCompare(author) == .orderedSame }
        }
    }

    public var narratorNames: [String] {
        let names = books.flatMap(\.book.narrators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.localizedCaseInsensitiveCompare("Unknown reader") != .orderedSame }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func books(byNarrator narrator: String) -> [BookWithChapters] {
        books.filter { book in
            book.book.narrators.contains { $0.localizedCaseInsensitiveCompare(narrator) == .orderedSame }
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
