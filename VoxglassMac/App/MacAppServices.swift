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

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let repository = LibraryRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let bookmarkStore = SQLiteBookmarkStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database, bookmarkStore: bookmarkStore)
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
        await libraryStore.refresh()
        await offlineDownloads.refreshState(for: libraryStore.books)
        await playback.restorePresentedSession(from: libraryStore.books)
    }

    func syncLibrary() async {
        await cloudSync.sync()
        await cloudKitSync.fetchChanges()
        await productionSync.checkForUpdates()
        await libraryStore.refresh()
    }
}
