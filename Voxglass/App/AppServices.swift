import Foundation
import ParsoAudioStreaming
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
    /// Activates the phone side of the WatchConnectivity audio relay so the watch
    /// can pull chapters the phone already has cached. Held for the app lifetime.
    let phoneAudioRelay = PhoneAudioRelay.shared
    /// The production preview + watch relay. Created lazily because constructing the
    /// sync coordinator must not run during `AppServices.init` in unentitled test
    /// processes; `PhoneProductionSync` builds its CloudKit stack on first sync.
    lazy var productionEnvironment: PhoneProductionEnvironment = PhoneProductionEnvironment()

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
                await self?.phoneAudioRelay.publishLibrarySnapshot()
            }
        }
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)
        libraryStore.configure(playback: playbackCoordinator, offlineManager: offlineDownloadManager)
        libraryStore.onBookImported = { [weak self] bookID in
            await self?.cloudSync.adoptCloudPositions(forBookID: bookID)
            self?.cloudKitSyncEngine.pushAfterMutation()
            await self?.phoneAudioRelay.publishLibrarySnapshot()
        }
        phoneAudioRelay.configure(
            libraryStore: self.libraryStore,
            playbackCoordinator: self.playbackCoordinator,
            offlineManager: self.offlineDownloadManager
        )
        playbackCoordinator.listeningStatsStore = listeningStatsStore
        folderWatchService.configure(libraryStore: libraryStore)

        playbackCoordinator.onTasteSignal = { [weak self] signal in
            guard let self else { return }
            Task {
                await self.captureTasteSignal(signal)
                // Keep the typed watch projection close to the phone's durable
                // savepoint while the listener is actively playing.
                await self.phoneAudioRelay.publishTypedWatchProjection()
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
        let diagnostics = LaunchDiagnostics.shared
        diagnostics.phase("library-refresh")
        await libraryStore.refresh()
        // Siri's spoken book names ("Play <book> in Voxglass") track the library.
        VoxglassIntentBridge.observeLibrary(libraryStore)
        await phoneAudioRelay.publishLibrarySnapshot()
        diagnostics.phase("playback-restore")
        await playbackCoordinator.reconcileSnapshots()
        await playbackCoordinator.restorePresentedSession(from: libraryStore.books)
        await phoneAudioRelay.publishLibrarySnapshot()

        // The first frame must not wait on cache eviction, migrations for
        // legacy metadata, folder audio probing, iCloud, or archive.org. Those
        // operations are useful, but none is required to show the already
        // persisted library and restore the paused player.
        homeRecommendationStore.markEngineReady()
        #if DEBUG
        // This is a local deterministic UI-test fixture, not launch
        // maintenance; keep it before the smoke test starts querying the
        // Narration surface.
        await seedProductionPreviewIfRequested()
        #endif
        diagnostics.markInteractive()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self.finishDeferredBootstrap()
        }
    }

    private func finishDeferredBootstrap() async {
        let diagnostics = LaunchDiagnostics.shared
        diagnostics.beginDeferredWork()

        diagnostics.phase("cache-maintenance")
        await AudioCache.evictToCurrentBudget()
        await AudioCache.shared.garbageCollectStalePartials()

        diagnostics.phase("local-url-rebase")
        let rebased = await libraryRepository.rebaseStaleLocalURLsIfNeeded()
        if rebased > 0 {
            await libraryStore.refresh()
            await phoneAudioRelay.publishLibrarySnapshot()
        }

        diagnostics.phase("legacy-metadata")
        await libraryStore.backfillNarratorsIfNeeded()
        await libraryRepository.backfillContentKeysIfNeeded()
        await enqueueInitialLibraryForCloudKitIfNeeded()
        await libraryRepository.backfillBookTasteIfNeeded()
        _ = await libraryRepository.resplitBookTasteSubjectsIfNeeded()
        await rebuildTasteHistory()

        diagnostics.phase("recommendations")
        homeRecommendationStore.markEngineReady()
        let selectedIDs = AppPreferencesStore.decodeCollectionIDs(
            UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.selectedCollectionIDs) ?? ""
        )
        let selectedLanguages = AppPreferencesStore.decodeLanguages(
            UserDefaults.standard.string(forKey: AppPreferencesStore.Keys.selectedLanguages) ?? "eng"
        )
        await homeRecommendationStore.load(selectedCollectionIDs: selectedIDs, selectedLanguages: selectedLanguages)

        diagnostics.phase("offline-state")
        await offlineDownloadManager.refreshState(for: libraryStore.books)

        diagnostics.phase("folder-watch")
        await folderWatchService.rescanAll()

        diagnostics.phase("cloud-positions")
        await cloudSync.pullPlaybackPositions()
        await playbackCoordinator.refreshPresentedSessionAfterCloudPull(from: libraryStore.books)

        let production = productionEnvironment
        phoneAudioRelay.registerProductionTransport(production.watchTransport)
        #if DEBUG
        let cloudBootstrapDisabled = ProcessInfo.processInfo.arguments.contains("-uiTestDisableCloudKit")
        #else
        let cloudBootstrapDisabled = false
        #endif
        diagnostics.phase("cloudkit-and-production")
        // Unsigned simulator UI-test bundles do not carry the CloudKit
        // entitlement. The smoke path is entirely local and explicitly opts
        // out before any CKContainer-backed service is touched.
        if !cloudBootstrapDisabled {
            await cloudSync.sync()
            await cloudKitSyncEngine.start()
            if cloudKitSyncEngine.lastUploadedCount > 0 {
                UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
            }
            // Pull production previews and relay them to the watch (spec §13.6).
            await production.checkForUpdates()
        }

        diagnostics.finishDeferredWork()
    }

    /// `-uiTestSeed onePreviewProject` seeds one previewable production so the
    /// iPhone smoke test can assert the My Productions surface is reachable
    /// (§18.2, WP-G). Debug-only; release builds ignore the argument.
    ///
    /// The reset flag first wipes the preview store's on-disk cache so the
    /// seeded card is the only project and cannot be pushed below the fold by
    /// stale previews left by earlier test runs (WP-G).
    #if DEBUG
    private func seedProductionPreviewIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestResetNarrations") {
            await productionEnvironment.previewStore.resetAll()
        }
        guard let index = arguments.firstIndex(of: "-uiTestSeed"),
              arguments.indices.contains(index + 1),
              arguments[index + 1] == "onePreviewProject" else { return }
        await productionEnvironment.previewStore.apply(ProductionSmokeSeed.projection())
    }
    #endif

    private func enqueueInitialLibraryForCloudKitIfNeeded() async {
        let defaults = UserDefaults.standard

        // First run of a sync-capable build: enqueue the existing backlog once.
        if !defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued) {
            await libraryRepository.enqueueExistingLibraryForSync()
            defaults.set(true, forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued)
            return
        }

        // Self-heal: the one-time enqueue already ran, but nothing is queued and
        // no upload has ever been confirmed — the library was likely stranded
        // (e.g. enqueue matched nothing, or every push failed). Re-enqueue.
        let uploadConfirmed = defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
        let pending = (try? await CloudSyncStateStore(database: database).pendingCount()) ?? 0
        if !uploadConfirmed && pending == 0 {
            _ = await libraryRepository.enqueueExistingLibraryForSync()
        }
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
