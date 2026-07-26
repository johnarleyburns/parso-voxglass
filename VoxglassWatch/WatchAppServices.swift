import Foundation
import VoxglassCore

@MainActor
final class WatchAppServices: ObservableObject {
    static let shared = WatchAppServices()

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

        WatchAudioRelay.shared.onFileReceived = { [weak self] url, chapterKey in
            guard let self else { return }
            Task { @MainActor in
                // Find the chapter by matching the cache key
                let library = try? await self.libraryRepository.fetchLibrary()
                for book in library ?? [] {
                    for chapter in book.chapters {
                        let remoteURL = chapter.remoteURL ?? chapter.opusURL
                        if let url = remoteURL,
                           StreamCacheUtils.key(for: url) == chapterKey {
                            await self.offlineManager.ingestFile(at: url, for: chapter, bookID: book.book.id)
                            return
                        }
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
        }

        await libraryStore.refresh()
        await restoreBookmark()

        #if DEBUG
        seedFixturesIfNeeded()
        #endif
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
        guard !defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued) else { return }
        await libraryRepository.enqueueExistingLibraryForSync()
        defaults.set(true, forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued)
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
