import Foundation
import VoxglassCore

@MainActor
final class AppServices: ObservableObject {
    /// Shared across the SwiftUI window scene and the CarPlay scene — both run
    /// in one process and must share one coordinator/library/audio engine
    /// (docs/CARPLAY_DESIGN.md §6.2).
    static let shared = AppServices()

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
        let playbackBridge = SystemPlaybackBridge()
        let tasteProfileStore = TasteProfileStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: bookmarkStore)
        let listeningStatsStore = ListeningStatsStore(database: database)

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore,
            bridge: playbackBridge
        )
        // The bridge forwards remote commands into the coordinator (set in its
        // init) and app-lifecycle / interruption events back the other way.
        playbackBridge.coordinator = self.playbackCoordinator
        // Cover art is fetched as raw bytes so the platform-free coordinator never
        // touches UIImage; the bridge renders it into lock-screen artwork.
        self.playbackCoordinator.artworkProvider = { url in
            await ArtworkService.shared.image(for: url)?.pngData()
        }
        // Cover resolution lives in Core but image decoding needs UIKit, so inject
        // the app-side validator into the (actor) resolver seam.
        Task { await InternetArchiveCoverResolver.shared.setArtworkValidator(ArtworkService.shared) }
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

        // Wire signal capture: when a taste-meaningful position save lands, apply
        // a thresholded, delta-based taste profile update (never per-tick counts).
        playbackCoordinator.onTasteSignal = { [weak self] signal in
            guard let self else { return }
            Task {
                await self.captureTasteSignal(signal)
            }
        }
    }

    /// Idempotent, once-only bootstrap, callable from either scene. The CarPlay
    /// scene can cold-launch the app with the phone locked (docs/CARPLAY_DESIGN.md
    /// §6.3), so whichever scene connects first runs the real bootstrap and the
    /// other becomes a no-op.
    func bootstrapOnce() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }

    private var didBootstrap = false

    func bootstrap() async {
        await StoreManager.shared.refreshEntitlement()
        await CacheManager.shared.evictIfNeeded()
        await CacheManager.shared.garbageCollectStalePartials()
        await libraryStore.refresh()
        await libraryStore.backfillNarratorsIfNeeded()
        await libraryRepository.backfillContentKeysIfNeeded()
        await libraryRepository.backfillBookTasteIfNeeded()
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

    /// Rebuilds local taste rows from authoritative history. This is intentionally
    /// idempotent, so it can run at launch and after meaningful playback signals
    /// without double-counting older field-test data. The version marker records
    /// the last rebuild shape; it does not gate the rebuild itself.
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
