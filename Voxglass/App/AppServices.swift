import Foundation
import VoxglassCore

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let database: AppDatabase
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let playbackCoordinator: PlaybackCoordinator
    let tasteProfileStore: TasteProfileStore
    let libraryRepository: LibraryRepository
    let cloudSync: VoxglassCloudSync
    let cloudKitSyncEngine: CloudKitSyncEngine
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
        var positionStore = SQLitePositionStore(database: database)
        var bookmarkStore = SQLiteBookmarkStore(database: database)
        let audioEngine = AVPlayerAudioEngine()
        let playbackBridge = SystemPlaybackBridge()
        let tasteProfileStore = TasteProfileStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: bookmarkStore)
        let cloudKitSyncEngine = CloudKitSyncEngine(database: database)
        let listeningStatsStore = ListeningStatsStore(database: database)

        let mutationLog = SyncMutationLog(stateStore: CloudSyncStateStore(database: database))
        libraryRepository.mutationLog = mutationLog
        positionStore.mutationLog = mutationLog
        bookmarkStore.mutationLog = mutationLog

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore,
            bridge: playbackBridge
        )
        playbackBridge.coordinator = self.playbackCoordinator
        self.playbackCoordinator.artworkProvider = { url in
            await ArtworkService.shared.image(for: url)?.pngData()
        }
        Task { await InternetArchiveCoverResolver.shared.setArtworkValidator(ArtworkService.shared) }
        let playlistStore = PlaylistStore(repository: playlistRepository)
        self.playlistStore = playlistStore
        self.tasteProfileStore = tasteProfileStore
        self.cloudSync = cloudSync
        self.cloudKitSyncEngine = cloudKitSyncEngine
        self.homeRecommendationStore = HomeRecommendationStore()
        self.offlineDownloadManager = OfflineDownloadManager(repository: libraryRepository)
        self.listeningStatsStore = listeningStatsStore
        self.folderWatchService = FolderWatchService(repository: libraryRepository)
        self.libraryBackupService = LibraryBackupService(database: database)
        self.playbackCoordinator.bookmarkStore = bookmarkStore
        self.playbackCoordinator.onBookmarkAdded = { [weak self] bookmark in
            Task { @MainActor [weak self] in
                await self?.cloudSync.pushBookmarks()
                self?.cloudKitSyncEngine.pushAfterMutation()
            }
        }
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)
        libraryStore.configure(playback: playbackCoordinator, offlineManager: offlineDownloadManager)
        libraryStore.onBookImported = { [weak self] bookID in
            await self?.cloudSync.adoptCloudPositions(forBookID: bookID)
            self?.cloudKitSyncEngine.pushAfterMutation()
        }
        playbackCoordinator.listeningStatsStore = listeningStatsStore
        folderWatchService.configure(libraryStore: libraryStore)

        playbackCoordinator.onTasteSignal = { [weak self] signal in
            guard let self else { return }
            Task {
                await self.captureTasteSignal(signal)
            }
        }
    }

    func bootstrapOnce() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }

    private var didBootstrap = false

    func bootstrap() async {
        await CacheManager.shared.evictIfNeeded()
        await CacheManager.shared.garbageCollectStalePartials()
        await libraryStore.refresh()
        let rebased = await libraryRepository.rebaseStaleLocalURLsIfNeeded()
        if rebased > 0 {
            await libraryStore.refresh()
        }
        await playbackCoordinator.reconcileSnapshots()
        await playbackCoordinator.restorePresentedSession(from: libraryStore.books)

        await libraryStore.backfillNarratorsIfNeeded()
        await libraryRepository.backfillContentKeysIfNeeded()
        await enqueueInitialLibraryForCloudKitIfNeeded()
        await libraryRepository.backfillBookTasteIfNeeded()
        await libraryRepository.resplitBookTasteSubjectsIfNeeded()
        await rebuildTasteHistory()
        homeRecommendationStore.markEngineReady()
        let selectedIDs = AppPreferencesStore.decodeCollectionIDs(
            UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.selectedCollectionIDs) ?? ""
        )
        let selectedLanguages = AppPreferencesStore.decodeLanguages(
            UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.selectedLanguages) ?? "eng"
        )
        await homeRecommendationStore.load(selectedCollectionIDs: selectedIDs, selectedLanguages: selectedLanguages)
        await offlineDownloadManager.refreshState(for: libraryStore.books)
        await folderWatchService.rescanAll()

        await cloudSync.pullPlaybackPositions()
        await playbackCoordinator.refreshPresentedSessionAfterCloudPull(from: libraryStore.books)

        Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            await self.cloudSync.sync()
            await self.cloudKitSyncEngine.start()
        }
    }

    private func enqueueInitialLibraryForCloudKitIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued) else { return }
        await libraryRepository.enqueueExistingLibraryForSync()
        defaults.set(true, forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued)
    }

    private func captureTasteSignal(_ signal: PlaybackTasteSignal) async {
        guard let terms = try? await libraryRepository.fetchBookTasteTerms(for: signal.bookID),
              !terms.isEmpty else {
            return
        }
        let changed = await tasteProfileStore.applySignal(signal, terms: terms)
        if changed {
            await rebuildTasteHistory()
        }
    }

    private static let tasteHistoryRebuildVersionKey = "voxglass.tasteHistoryRebuiltVersion"

    private func rebuildTasteHistory() async {
        let selectedIDs = AppPreferencesStore.decodeCollectionIDs(
            UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.selectedCollectionIDs) ?? ""
        )
        await tasteProfileStore.rebuildFromListeningHistory(
            version: TasteProfileStore.listeningHistoryRebuildVersion,
            selectedCollectionIDs: selectedIDs
        )
        UserDefaults.standard.set(
            TasteProfileStore.listeningHistoryRebuildVersion,
            forKey: Self.tasteHistoryRebuildVersionKey
        )
    }
}
