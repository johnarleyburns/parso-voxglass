import Foundation
import Observation
import ParsoAudioStreaming
import VoxglassCore

@MainActor
final class MacAppServices: ObservableObject {
    let database: AppDatabase
    let libraryRepository: LibraryRepository
    let libraryStore: LibraryStore
    let catalogStore: CatalogStore
    let playback: PlaybackCoordinator
    let offlineDownloads: OfflineDownloadManager
    let cloudSync: VoxglassCloudSync
    let cloudKitSync: CloudKitSyncEngine
    let narrationRepository: NarrationProjectRepository
    let productionSync: MacProductionSync
    let capture: MacAudioCapture
    private var automaticSyncTask: Task<Void, Never>?

    init(database: AppDatabase = AppDatabase.makeApplicationDatabase()) {
        let repository = LibraryRepository(database: database)
        var positionStore = SQLitePositionStore(database: database)
        var bookmarkStore = SQLiteBookmarkStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: bookmarkStore)
        let mutationLog = SyncMutationLog(stateStore: CloudSyncStateStore(database: database))
        repository.mutationLog = mutationLog
        positionStore.mutationLog = mutationLog
        bookmarkStore.mutationLog = mutationLog
        let playback = PlaybackCoordinator(
            engine: MacPlaybackAudioEngine(),
            positionStore: positionStore,
            bridge: MacPlaybackBridge()
        )
        let offline = OfflineDownloadManager(repository: repository)

        self.database = database
        self.libraryRepository = repository
        self.libraryStore = LibraryStore(repository: repository)
        self.catalogStore = CatalogStore()
        self.playback = playback
        self.offlineDownloads = offline
        self.cloudSync = cloudSync
        self.narrationRepository = NarrationProjectRepository()
        self.cloudKitSync = CloudKitSyncEngine(database: database)
        self.productionSync = MacProductionSync(repository: narrationRepository)
        self.capture = MacAudioCapture()

        playback.bookmarkStore = bookmarkStore
        libraryStore.configure(playback: playback, offlineManager: offline)
        libraryStore.onBookImported = { [weak self] bookID in
            await self?.cloudSync.adoptCloudPositions(forBookID: bookID)
            await self?.cloudSync.pushPlaybackPositions()
        }
    }

    func bootstrap() async {
        await MacSyncBootstrap.run(
            local: { [weak self] in
                guard let self else { return }
                await self.libraryStore.refresh()
                await self.libraryRepository.backfillContentKeysIfNeeded()
                await self.enqueueInitialLibraryForCloudKitIfNeeded()
                await self.offlineDownloads.refreshState(for: self.libraryStore.books)
                await self.playback.restorePresentedSession(from: self.libraryStore.books)
            },
            sync: { [weak self] in
                guard let self else { return }
                await self.syncLibrary()
            }
        )
        startAutomaticSync()
    }

    func syncLibrary() async {
        guard cloudSync.isEnabled else { return }
        await cloudSync.sync()
        await cloudKitSync.start()
        if cloudKitSync.lastUploadedCount > 0 {
            UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
        }
        await productionSync.checkForUpdates()
        await libraryStore.refresh()
    }

    private func startAutomaticSync() {
        guard automaticSyncTask == nil else { return }
        automaticSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.syncLibrary()
            }
        }
    }

    private func enqueueInitialLibraryForCloudKitIfNeeded() async {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued) {
            _ = await libraryRepository.enqueueExistingLibraryForSync()
            defaults.set(true, forKey: AppPreferencesStore.Keys.cloudKitInitialLibraryEnqueued)
            return
        }

        let uploadConfirmed = defaults.bool(forKey: AppPreferencesStore.Keys.cloudKitLibraryUploadConfirmed)
        let pending = (try? await CloudSyncStateStore(database: database).pendingCount()) ?? 0
        if !uploadConfirmed && pending == 0 {
            _ = await libraryRepository.enqueueExistingLibraryForSync()
        }
    }

    deinit {
        automaticSyncTask?.cancel()
    }
}
