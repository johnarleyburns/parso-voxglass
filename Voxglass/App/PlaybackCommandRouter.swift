import Foundation
import VoxglassCore

/// App-process implementation for commands defined in `VoxglassShared`.
@MainActor
enum PlaybackCommandRouter {
    static func perform(_ command: PlaybackCommand) async throws {
        let services = await VoxglassIntentBridge.prepare()
        let coordinator = services.playbackCoordinator
        switch command {
        case .resume:
            if coordinator.currentSession == nil {
                await coordinator.restorePresentedSession(from: services.libraryStore.books)
            }
            if let session = coordinator.currentSession {
                if !session.isPlaying { coordinator.togglePlayPause() }
            } else if let book = services.libraryStore.recentlyPlayed.first {
                await coordinator.play(book)
            }
        case .togglePlayPause:
            coordinator.togglePlayPause()
        case .skipBackward:
            await coordinator.skip(by: -TimeInterval(AppPreferencesStore.defaultSkipBackInterval))
        case .skipForward:
            await coordinator.skip(by: TimeInterval(AppPreferencesStore.defaultSkipForwardInterval))
        case .cycleSleepTimer:
            switch coordinator.sleepMode {
            case .off: coordinator.setSleepTimer(.duration(30 * 60))
            case .duration: coordinator.setSleepTimer(.endOfChapter)
            case .endOfChapter: coordinator.setSleepTimer(.off)
            }
        }
    }
}

private extension AppPreferencesStore {
    static var defaultSkipBackInterval: Int {
        let value = UserDefaults.standard.integer(forKey: Keys.skipBackInterval)
        return value > 0 ? value : 15
    }

    static var defaultSkipForwardInterval: Int {
        let value = UserDefaults.standard.integer(forKey: Keys.skipForwardInterval)
        return value > 0 ? value : 30
    }
}
