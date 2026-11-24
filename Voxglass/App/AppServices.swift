import Foundation
import ParsoAudioStreaming
import VoxglassCore

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let database: AppDatabase
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let gutenbergIndexStore: GutenbergIndexStore
    let playbackCoordinator: PlaybackCoordinator
    /// The shared platform bridge; CarPlay review metadata routes through it.
    let playbackBridge: any PlaybackPlatformBridge
    let tasteProfileStore: TasteProfileStore
    let libraryRepository: LibraryRepository
    let homeRecommendationStore: HomeRecommendationStore
    let offlineDownloadManager: OfflineDownloadManager
    let listeningStatsStore: ListeningStatsStore
    let folderWatchService: FolderWatchService
    let playlistStore: PlaylistStore
    let libraryBackupService: LibraryBackupService
    /// Activates the phone side of the WatchConnectivity audio relay so the watch
    /// can pull chapters the phone already has cached. Held for the app lifetime.
    let phoneAudioRelay = PhoneAudioRelay.shared

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let playlistRepository = PlaylistRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let bookmarkStore = SQLiteBookmarkStore(database: database)
        let audioEngine = SwitchingAudioEngine(audio: AVPlayerAudioEngine(), speech: ReadWithAISpeechAudioEngine())
        let playbackBridge = SystemPlaybackBridge()
        let tasteProfileStore = TasteProfileStore(database: database)
        let listeningStatsStore = ListeningStatsStore(database: database)

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.gutenbergIndexStore = GutenbergIndexStore(
            baseURL: URL(string: "https://gutenberg.parso.guru")!
        )
        self.playbackBridge = playbackBridge
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore,
            bridge: playbackBridge
        )
        playbackBridge.coordinator = self.playbackCoordinator
        self.playbackCoordinator.localSourceContextProvider = { [libraryRepository] bookID in
            await libraryRepository.localSourceContext(bookID: bookID)
        }
        self.playbackCoordinator.artworkProvider = { url in
            await ArtworkService.shared.image(for: url)?.pngData()
        }
        self.playbackCoordinator.cachedArtworkProvider = { url in
            ArtworkService.shared.cachedImage(for: url)?.pngData()
        }
        self.playbackCoordinator.artworkConsumer = { bookID, data in
            CoverThumbnailStore.save(imageData: data, bookID: bookID)
        }
        Task { await InternetArchiveCoverResolver.shared.setArtworkValidator(ArtworkService.shared) }
        let playlistStore = PlaylistStore(repository: playlistRepository)
        self.playlistStore = playlistStore
        self.tasteProfileStore = tasteProfileStore
        self.homeRecommendationStore = HomeRecommendationStore()
        self.offlineDownloadManager = OfflineDownloadManager(repository: libraryRepository)
        self.listeningStatsStore = listeningStatsStore
        self.folderWatchService = FolderWatchService(repository: libraryRepository)
        self.libraryBackupService = LibraryBackupService(database: database)
        self.playbackCoordinator.bookmarkStore = bookmarkStore
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)
        libraryStore.configure(playback: playbackCoordinator, offlineManager: offlineDownloadManager)
        libraryStore.onBookImported = { [weak self] _ in
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
        // legacy metadata, folder audio probing, or archive.org. Those
        // operations are useful, but none is required to show the already
        // persisted library and restore the paused player.
        homeRecommendationStore.markEngineReady()
        diagnostics.markInteractive()

        // Deferred past scene creation and detached from the rest of deferred
        // bootstrap: a slow session daemon must not delay or block anything.
        Task { @MainActor [weak self] in
            guard let self else { return }
            diagnostics.noteOfflineSession("activating")
            let ready = await self.offlineDownloadManager.activateSession()
            diagnostics.noteOfflineSession(ready ? "ready" : "failed")
        }

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
        let repairedIdentities = await libraryRepository.backfillRecordingIdentitiesIfNeeded()
        if repairedIdentities > 0 { await libraryStore.refresh() }
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

        diagnostics.finishDeferredWork()
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
