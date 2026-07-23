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

    #if DEBUG
    var seededFixtures: [BookWithChapters] = []
    #endif

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let bookmarkStore = SQLiteBookmarkStore(database: database)

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
    }

    func bootstrap() async {
        // Restore last session from CloudSync/persisted position
        if let row = try? await positionStore.latestPosition(),
           let book = libraryStore.books.first(where: { $0.book.id == row.bookID }) {
            playbackCoordinator.present(book)
        }
        await libraryStore.refresh()
        #if DEBUG
        seedFixturesIfNeeded()
        #endif
    }

    /// Restores position after iCloud pull arrives (same contract as phone).
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
