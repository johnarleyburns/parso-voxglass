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
        self.playbackCoordinator.bookmarkStore = bookmarkStore
        self.playbackCoordinator.onBookmarkAdded = { [weak self] bookmark in
            Task { @MainActor [weak self] in
                await self?.cloudSync.pushBookmarks()
            }
        }
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)
        libraryStore.configure(playback: playbackCoordinator, offlineManager: offlineDownloadManager)
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
        await CacheManager.shared.evictIfNeeded()
        await CacheManager.shared.garbageCollectStalePartials()
        await libraryStore.refresh()
        await offlineDownloadManager.refreshState(for: libraryStore.books)
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
}
