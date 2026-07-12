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

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let audioEngine = AVPlayerAudioEngine()
        let tasteProfileStore = TasteProfileStore(database: database)
        let cloudSync = VoxglassCloudSync(database: database)

        self.database = database
        self.libraryRepository = libraryRepository
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.catalogStore = CatalogStore()
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore
        )
        self.tasteProfileStore = tasteProfileStore
        self.cloudSync = cloudSync
        self.homeRecommendationStore = HomeRecommendationStore()
        homeRecommendationStore.configure(profileStore: tasteProfileStore, libraryStore: libraryStore)

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
        await playbackCoordinator.restoreLatestSession(from: libraryStore.books)
        await cloudSync.sync()
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
