import Foundation

@MainActor
final class AppServices: ObservableObject {
    let database: AppDatabase
    let libraryStore: LibraryStore
    let playbackCoordinator: PlaybackCoordinator

    init() {
        let database = AppDatabase.makeApplicationDatabase()
        let libraryRepository = LibraryRepository(database: database)
        let positionStore = SQLitePositionStore(database: database)
        let audioEngine = AVPlayerAudioEngine()

        self.database = database
        self.libraryStore = LibraryStore(repository: libraryRepository)
        self.playbackCoordinator = PlaybackCoordinator(
            engine: audioEngine,
            positionStore: positionStore
        )
    }

    func bootstrap() async {
        await libraryStore.refresh()
        await playbackCoordinator.restoreLatestSession(from: libraryStore.books)
    }
}

