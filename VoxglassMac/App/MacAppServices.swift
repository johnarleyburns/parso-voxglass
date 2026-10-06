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
    let cloudKitSync: CloudKitSyncEngine?
    let narrationRepository: NarrationProjectRepository
    let productionSync: MacProductionSync
    let capture: MacAudioCapture
    let uiTestBook: BookWithChapters?
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
        self.cloudKitSync = Self.isRunningUITests
            ? nil
            : CloudKitSyncEngine(database: database)
        self.productionSync = MacProductionSync(repository: narrationRepository)
        self.capture = MacAudioCapture()
        self.uiTestBook = Self.makeUITestBookIfRequested()

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
                guard !self.isCloudKitDisabledForUITest else { return }
                await self.syncLibrary()
            }
        )
        startAutomaticSync()
    }

    func syncLibrary() async {
        guard !isCloudKitDisabledForUITest else { return }
        guard cloudSync.isEnabled else { return }
        await cloudSync.sync()
        guard let cloudKitSync else { return }
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

    private var isCloudKitDisabledForUITest: Bool {
        Self.isRunningUITests
    }

    private static var isRunningUITests: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        return arguments.contains("-uiTestDisableCloudKit") ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil
        #else
        return false
        #endif
    }

    deinit {
        automaticSyncTask?.cancel()
    }

    #if DEBUG
    private static func makeUITestBookIfRequested() -> BookWithChapters? {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestSeedBook") else { return nil }
        let bookID = UUID(uuidString: "8B4C7B13-3A1F-4D69-9BE5-ED65C8B8A4D0")!
        let sourceID = UUID(uuidString: "3E1F5A2E-6C1B-4F90-8A0C-7B9B7D88D6E1")!
        let book = Book(
            id: bookID,
            title: "The Mac Playback Test Book",
            authors: ["Voxglass Test Author"],
            narrators: ["Voxglass Test Narrator"],
            summary: "A deterministic book fixture for the native Mac detail and Now Playing UI tests.",
            sourceID: sourceID,
            coverURL: URL(string: "https://archive.org/download/voxglass-ui-test/voxglass-ui-test_cover.jpg")
        )
        let chapter = Chapter(
            bookID: bookID,
            title: "A chapter with full controls",
            index: 0,
            duration: 600,
            remoteURL: URL(string: "https://example.invalid/voxglass-ui-test.mp3")
        )
        return BookWithChapters(book: book, chapters: [chapter])
    }
    #else
    private static func makeUITestBookIfRequested() -> BookWithChapters? { nil }
    #endif
}
