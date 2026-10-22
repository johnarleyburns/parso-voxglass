import Foundation
import ParsoAudioStreaming

@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var books: [BookWithChapters] = [] {
        didSet { rebuildOwnedIdentifierIndex() }
    }
    @Published public private(set) var sources: [Source] = [] {
        didSet { rebuildOwnedIdentifierIndex() }
    }
    /// IA identifier -> owned (non-pending) book ID, rebuilt whenever the
    /// published `books`/`sources` snapshot changes so rows never hit storage.
    private var ownedBookIDByIdentifier: [String: UUID] = [:]
    @Published public private(set) var recentlyPlayed: [BookWithChapters] = []
    @Published public private(set) var isImporting = false
    @Published public var importError: String?

    /// P1-2: in-memory primary scope + sort. Changing these recomputes
    /// `visibleBooks` with zero DB round-trips. Advanced My Books refinements
    /// remain independent so the segmented progress control always has a
    /// selected value.
    @Published public var progressFilter: LibraryProgressFilter = .inProgress
    @Published public var favoriteOnly = false
    @Published public var downloadedOnly = false
    /// Legacy mixed filter retained for non-UI callers. New UI code should use
    /// `progressFilter`, `favoriteOnly`, and `downloadedOnly` separately.
    @Published public var filter: LibraryBookFilter = .all {
        didSet {
            switch filter {
            case .all:
                progressFilter = .all
                favoriteOnly = false
                downloadedOnly = false
            case .favorites:
                progressFilter = .all
                favoriteOnly = true
                downloadedOnly = false
            case .downloaded:
                progressFilter = .all
                favoriteOnly = false
                downloadedOnly = true
            case .finished:
                progressFilter = .finished
                favoriteOnly = false
                downloadedOnly = false
            case .inProgress:
                progressFilter = .inProgress
                favoriteOnly = false
                downloadedOnly = false
            case .source:
                break
            }
        }
    }
    @Published public var sort: LibrarySort = .recent
    @Published public private(set) var progressByBook: [UUID: BookProgress] = [:]
    @Published public private(set) var listenedWorkExclusionKeys: Set<String> = []

    /// The library with the active filter/sort applied. Pure, in-memory.
    public var visibleBooks: [BookWithChapters] {
        // A book only previewed from a catalog result (not yet explicitly
        // added via the book page's "+" button) never shows in My Books —
        // it stays resolvable (for playback and history) via `books`/
        // `book(withID:)`, just not surfaced in this list.
        var result = books.filter { !$0.book.isPending }

        switch progressFilter {
        case .all: break
        case .finished:
            result = result.filter { progressByBook[$0.book.id]?.isFinished == true }
        case .inProgress:
            result = result.filter {
                // An added book is In Progress by default, even if unplayed.
                guard let p = progressByBook[$0.book.id] else { return true }
                return !p.isFinished
            }
        }

        if favoriteOnly {
            result = result.filter(\.book.isFavorite)
        }
        if downloadedOnly {
            // Keep the in-memory view consistent with the My Books UI: only
            // fully cached books belong in the Downloaded refinement. The
            // repository's async filter remains available for non-UI callers,
            // while this path stays responsive and updates as the manager's
            // published state changes.
            result = result.filter { offlineManager?.state(for: $0.book.id) == .cached }
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
            let fetchedBooks = try await repository.fetchLibrary()
            books = fetchedBooks
            sources = try await repository.fetchSources()
            recentlyPlayed = try await repository.fetchRecentlyPlayed(from: fetchedBooks)
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

    public func fetchListeningHistory() async -> [(book: BookWithChapters, lastPlayedAt: Date)] {
        (try? await repository.fetchListeningHistory()) ?? []
    }

    public func removeListeningHistory(bookID: UUID) async {
        try? await repository.removeListeningHistory(bookID: bookID)
    }

    public func clearAllListeningHistory() async {
        try? await repository.clearAllListeningHistory()
    }

    /// Marks a just-previewed catalog result pending — it plays normally but
    /// stays out of My Books until confirmed.
    public func markBookPending(_ bookID: UUID) async {
        try? await repository.setBookPending(true, for: bookID)
        await refresh()
    }

    /// "Add to My Books?" confirmed — the book behaves like any other from
    /// here on.
    public func confirmAddToLibrary(_ bookID: UUID) async {
        try? await repository.setBookPending(false, for: bookID)
        await refresh()
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

    /// Renews bookmarks for imported files under a user-reselected folder or
    /// file. The caller must hold security-scoped access to `url`.
    @discardableResult
    public func repairLocalAccess(selected url: URL) async -> Int {
        do {
            let repaired = try await repository.repairLocalFileBookmarks(forFolder: url)
            if repaired > 0 { await refresh() }
            return repaired
        } catch {
            importError = error.localizedDescription
            return 0
        }
    }

    /// Book-scoped Reconnect Audio. `mapping == nil` returns a preview only;
    /// the library is refreshed after a successful commit.
    public func repairLocalAudio(bookID: UUID, selection: URL, mapping: [UUID: URL]?) async -> LocalAudioRepairOutcome {
        let outcome = await repository.repairLocalAudio(bookID: bookID, selection: selection, mapping: mapping)
        if case .success = outcome { await refresh() }
        return outcome
    }

    @discardableResult
    public func importLocalSingleFile(
        folderURL: URL,
        folderName: String,
        audioURL: URL,
        bookmark: Data,
        markers: [LocalChapterMarker],
        audioDuration: TimeInterval?,
        coverURL: URL? = nil
    ) async -> BookWithChapters? {
        isImporting = true
        defer { isImporting = false }

        let imports = markers.enumerated().map { index, marker in
            let end = markers.indices.contains(index + 1)
                ? markers[index + 1].startTime
                : audioDuration
            let duration = end.map { max(0, $0 - marker.startTime) }
            return LocalAudioImport(
                url: audioURL,
                title: marker.title,
                sortKey: String(format: "%04d", marker.number),
                duration: duration,
                startTime: marker.startTime,
                bookmark: bookmark
            )
        }

        do {
            let imported = try await repository.importLocalFolder(
                folderURL: folderURL,
                folderName: folderName,
                files: imports,
                coverURL: coverURL
            )
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
                keys.append(AudioCache.key(for: remoteURL))
            }
            if let opusURL = chapter.opusURL {
                keys.append(AudioCache.key(for: opusURL))
            }
        }
        if let coverURL = book.book.coverURL {
            keys.append(ArtworkCacheKey.key(for: coverURL))
        }
        if !keys.isEmpty {
            await AudioCache.shared.remove(keys: keys)
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

    /// Synchronous display hint for result rows: a non-pending owned book in the
    /// published snapshot, matched through the cached identity index (source
    /// details URL content key, then unambiguous chapter download URLs). The
    /// async resolver below is authoritative.
    public func cachedOwnedBook(forInternetArchiveIdentifier identifier: String) -> BookWithChapters? {
        guard let bookID = ownedBookIDByIdentifier[identifier] else { return nil }
        return books.first { $0.book.id == bookID && !$0.book.isPending }
    }

    public func cachedBook(forInternetArchiveIdentifier identifier: String) -> BookWithChapters? {
        cachedOwnedBook(forInternetArchiveIdentifier: identifier)
    }

    private func rebuildOwnedIdentifierIndex() {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var index: [String: UUID] = [:]
        var chapterDerived: [String: UUID] = [:]
        for entry in books where !entry.book.isPending {
            if let source = sourcesByID[entry.book.sourceID],
               let key = ContentKey.book(forSourceURL: source.url, kind: source.kind),
               key.hasPrefix("ia:") {
                let identifier = String(key.dropFirst(3))
                if index[identifier] == nil { index[identifier] = entry.book.id }
            }
            var identifiers = Set<String>()
            for chapter in entry.chapters {
                for url in [chapter.remoteURL, chapter.opusURL].compactMap({ $0 }) {
                    if let id = ContentKey.internetArchiveIdentifier(fromDownloadURL: url) {
                        identifiers.insert(id)
                    }
                }
            }
            if identifiers.count == 1, let id = identifiers.first, chapterDerived[id] == nil {
                chapterDerived[id] = entry.book.id
            }
        }
        for (id, bookID) in chapterDerived where index[id] == nil {
            index[id] = bookID
        }
        ownedBookIDByIdentifier = index
    }

    /// Resolves the durable record (owned or pending preview) for an IA item,
    /// preferring the published snapshot, then durable storage.
    public func book(forInternetArchiveIdentifier identifier: String) async -> BookWithChapters? {
        let detailsURL = InternetArchiveMetadata.detailsURL(for: identifier)
        if let source = sources.first(where: { $0.url == detailsURL }),
           let book = books.first(where: { $0.book.sourceID == source.id }) {
            return book
        }
        do {
            let resolved = try await repository.bookWithChapters(forInternetArchiveIdentifier: identifier)
            if let resolved, !books.contains(where: { $0.book.id == resolved.book.id }) {
                // Snapshot was stale; republish so result rows reflect ownership.
                await refresh()
            }
            return resolved
        } catch {
            importError = error.localizedDescription
            return nil
        }
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
