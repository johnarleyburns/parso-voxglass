import Foundation

@MainActor
final class AppServices: ObservableObject {
    let database: AppDatabase
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let playbackCoordinator: PlaybackCoordinator
    let tasteProfileStore: TasteProfileStore
    let libraryRepository: LibraryRepository
    let cloudSync: VoxglassCloudSync
    let homeRecommendationStore: HomeRecommendationStore
    let offlineDownloadManager: OfflineDownloadManager
    let listeningStatsStore: ListeningStatsStore
    let folderWatchService: FolderWatchService
    let playlistStore: PlaylistStore
    let libraryBackupService: LibraryBackupService

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let playlistRepository = PlaylistRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let bookmarkStore = SQLiteBookmarkStore(database: database)
        let audioEngine = AVPlayerAudioEngine()
        let tasteProfileStore = TasteProfileStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: bookmarkStore)
        let listeningStatsStore = ListeningStatsStore(database: database)

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore
        )
        let playlistStore = PlaylistStore(repository: playlistRepository)
        self.playlistStore = playlistStore
        self.tasteProfileStore = tasteProfileStore
        self.cloudSync = cloudSync
        self.homeRecommendationStore = HomeRecommendationStore()
        self.offlineDownloadManager = OfflineDownloadManager(repository: libraryRepository)
        self.listeningStatsStore = listeningStatsStore
        self.folderWatchService = FolderWatchService(repository: libraryRepository)
        self.libraryBackupService = LibraryBackupService(database: database)
        self.playbackCoordinator.bookmarkStore = bookmarkStore
        self.playbackCoordinator.onBookmarkAdded = { [weak self] bookmark in
            Task { @MainActor [weak self] in
                await self?.cloudSync.pushBookmarks()
            }
        }
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)
        libraryStore.configure(playback: playbackCoordinator, offlineManager: offlineDownloadManager)
        libraryStore.onBookImported = { [weak self] bookID in
            await self?.cloudSync.adoptCloudPositions(forBookID: bookID)
        }
        playbackCoordinator.listeningStatsStore = listeningStatsStore
        folderWatchService.configure(libraryStore: libraryStore)

        // Wire signal capture: when a position is saved, seed taste profile
        playbackCoordinator.onPositionSaved = { [weak self] bookID, isFavorite in
            guard let self else { return }
            Task {
                await self.captureTasteSignal(bookID: bookID, isFavorite: isFavorite)
            }
        }
    }

    func bootstrap() async {
        await StoreManager.shared.refreshEntitlement()
        await CacheManager.shared.evictIfNeeded()
        await CacheManager.shared.garbageCollectStalePartials()
        await libraryStore.refresh()
        await libraryStore.backfillNarratorsIfNeeded()
        await libraryRepository.backfillContentKeysIfNeeded()
        await seedTasteHistoryIfNeeded()
        await offlineDownloadManager.refreshState(for: libraryStore.books)
        // Positions first: the KVS read is local and cheap. Doing this before the
        // restore (instead of inside sync() after it) means a cloud position is
        // applied this launch, not one launch late. Then replay the UserDefaults
        // snapshots into SQLite before restoring from it.
        await cloudSync.pullPlaybackPositions()
        await playbackCoordinator.reconcileSnapshots()
        await playbackCoordinator.restoreLatestSession(from: libraryStore.books)
        await cloudSync.sync()
        await folderWatchService.rescanAll()
    }

    private func captureTasteSignal(bookID: UUID, isFavorite: Bool) async {
        guard let terms = try? await libraryRepository.fetchBookTasteTerms(for: bookID) else {
            return
        }
        for (axis, term) in terms {
            let increment = isFavorite ? RecommendationConstants.favoriteBoost : 1.0
            await tasteProfileStore.upsertTerm(axis: axis, term: term, increment: increment)
        }
    }

    /// Runs the one-time history backfill so pre-existing listening shapes the
    /// recommendation shelf. Guarded by a persistent flag so it never re-runs and
    /// double-counts. Not stored under `AppPreferencesStore.Keys` (it is an
    /// internal migration marker, not a user preference).
    private static let tasteHistoryBackfillKey = "voxglass.tasteHistoryBackfilledV1"

    private func seedTasteHistoryIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.tasteHistoryBackfillKey) else { return }
        await tasteProfileStore.seedFromHistory()
        UserDefaults.standard.set(true, forKey: Self.tasteHistoryBackfillKey)
    }
}
