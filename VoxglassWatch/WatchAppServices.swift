import Foundation
import Combine
import VoxglassCore

@MainActor
final class WatchAppServices: ObservableObject {
    static let shared = WatchAppServices()

    private var cancellables = Set<AnyCancellable>()

    let database: AppDatabase
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let libraryRepository: LibraryRepository
    let positionStore: SQLitePositionStore
    let snapshotStore: LastPlaybackSnapshotStore
    let bookmarkStore: SQLiteBookmarkStore
    let playbackCoordinator: WatchPlaybackCoordinator
    let offlineManager: WatchStorageManager
    let syncEngine: CloudKitSyncEngine?

    #if DEBUG
    var seededFixtures: [BookWithChapters] = []
    #endif

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        var positionStore = SQLitePositionStore(database: database)
        var bookmarkStore = SQLiteBookmarkStore(database: database)

        let mutationLog = SyncMutationLog(stateStore: CloudSyncStateStore(database: database))
        libraryRepository.mutationLog = mutationLog
        positionStore.mutationLog = mutationLog
        bookmarkStore.mutationLog = mutationLog

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.positionStore = positionStore
        self.snapshotStore = LastPlaybackSnapshotStore()
        self.bookmarkStore = bookmarkStore
        self.playbackCoordinator = WatchPlaybackCoordinator(
            positionStore: positionStore,
            snapshotStore: snapshotStore
        )
        self.offlineManager = WatchStorageManager(
            repository: libraryRepository,
            positionStore: positionStore
        )
        self.syncEngine = CloudKitSyncEngine(database: database)

        libraryStore.onBookImported = { [weak self] _ in
            self?.syncEngine?.pushAfterMutation()
        }

        // Play downloaded books from the on-watch cache instead of streaming.
        playbackCoordinator.localURLProvider = { [weak self] chapter in
            self?.offlineManager.localURL(for: chapter)
        }

        // Re-publish the sync engine's state (syncError, counts) through this
        // container so views observing WatchAppServices update live — otherwise
        // errors would only appear after an unrelated re-render.
        syncEngine?.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        WatchAudioRelay.shared.onFileReceived = { [weak self] fileURL, chapterKey in
            guard let self else { return }
            Task { @MainActor in
                // Match the received file to a chapter by its canonical cache key,
                // then ingest the *received file* (not the remote URL).
                let library = try? await self.libraryRepository.fetchLibrary()
                for book in library ?? [] {
                    for chapter in book.chapters where WatchChapterCache.key(for: chapter) == chapterKey {
                        await self.offlineManager.ingestFile(at: fileURL, for: chapter, bookID: book.book.id)
                        return
                    }
                }
            }
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        await libraryStore.refresh()
        await offlineManager.refresh()
        await enqueueInitialLibraryForCloudKitIfNeeded()

        if let engine = syncEngine {
            await engine.start()
            if engine.lastUploadedCount > 0 {
                UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
            }
        }

        await libraryStore.refresh()
        await restoreBookmark()

        #if DEBUG
        seedFixturesIfNeeded()
        #endif
    }

    /// Downloads a book's chapters for offline use. When the paired iPhone is
    /// reachable it first asks the phone for any chapters it already has cached
    /// (a WatchConnectivity accelerator that saves cellular/IA bandwidth), then
    /// falls back to fetching the rest directly from Internet Archive so a
    /// download never *depends* on the phone being present.
    func downloadBook(_ book: BookWithChapters) async {
        let relay = WatchAudioRelay.shared
        if relay.isReachable && relay.isCompanionAppInstalled {
            for chapter in book.chapters where offlineManager.localURL(for: chapter) == nil {
                if let key = WatchChapterCache.key(for: chapter) {
                    relay.requestChapter(book.book.title, chapterKey: key)
                }
            }
            // Brief head start for the phone to deliver cached chapters before we
            // spend bandwidth fetching them ourselves.
            try? await Task.sleep(for: .seconds(2))
        }
        for chapter in book.chapters where offlineManager.localURL(for: chapter) == nil {
            try? await offlineManager.downloadChapter(chapter, bookID: book.book.id)
        }
    }

    func restoreBookmark() async {
        if let row = try? await positionStore.latestPosition(),
           let book = libraryStore.books.first(where: { $0.book.id == row.bookID }) {
            let chapters = book.chapters.naturallySorted()
            if let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: row) {
                playbackCoordinator.present(book, chapter: target.chapter)
            } else {
                playbackCoordinator.present(book)
            }
        }
    }

    func adoptCloudPosition() async {
        guard playbackCoordinator.currentSession?.isPlaying != true else { return }
        if let row = try? await positionStore.latestPosition(),
           let book = libraryStore.books.first(where: { $0.book.id == row.bookID }) {
            let chapters = book.chapters.naturallySorted()
            if let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: row) {
                playbackCoordinator.present(book, chapter: target.chapter)
            }
        }
    }

    private var didBootstrap = false

    private func enqueueInitialLibraryForCloudKitIfNeeded() async {
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued) {
            await libraryRepository.enqueueExistingLibraryForSync()
            defaults.set(true, forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued)
            return
        }

        // Self-heal: re-enqueue any locally-added books that were never confirmed
        // uploaded when nothing is currently queued.
        let uploadConfirmed = defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
        let pending = (try? await CloudSyncStateStore(database: database).pendingCount()) ?? 0
        if !uploadConfirmed && pending == 0 {
            _ = await libraryRepository.enqueueExistingLibraryForSync()
        }
    }

    #if DEBUG
    private func seedFixturesIfNeeded() {
        guard seededFixtures.isEmpty else { return }
        seededFixtures = WatchSeedFixtures.make()
    }
    #endif
}

#if DEBUG
public enum WatchSeedFixtures {
    public static func make() -> [BookWithChapters] {
        let bookID = UUID()
        let book = Book(
            id: bookID,
            title: "Pride and Prejudice",
            authors: ["Jane Austen"],
            narrators: ["Karen Savage"],
            summary: "Pride and Prejudice is the second novel by English author Jane Austen, published in 1813. A novel of manners, it follows the character development of Elizabeth Bennet, the protagonist of the book, who learns about the repercussions of hasty judgments and comes to appreciate the difference between superficial goodness and actual goodness.",
            sourceID: UUID()
        )
        let chapters: [Chapter] = (1...5).map { i in
            Chapter(
                id: UUID(),
                bookID: bookID,
                title: "Chapter \(i)",
                index: i,
                duration: 1200
            )
        }
        return [BookWithChapters(book: book, chapters: chapters)]
    }
}
#endif
