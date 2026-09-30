import SwiftUI
import Observation

enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}

@MainActor
@Observable
final class MiniPlayerPresentationRouter {
    var isNowPlayingPresented = false
    private var pushedPlayerCount = 0

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.isNowPlayingPresented },
            set: { self.isNowPlayingPresented = $0 }
        )
    }

    func playerPushed() { pushedPlayerCount += 1 }
    func playerPopped() { pushedPlayerCount = max(0, pushedPlayerCount - 1) }

    func shouldShowMiniPlayer(currentBookID: UUID?) -> Bool {
        guard currentBookID != nil else { return false }
        guard !isNowPlayingPresented else { return false }
        guard pushedPlayerCount == 0 else { return false }
        return true
    }

    func presentNowPlayingFromMiniPlayer(currentBookID: UUID?) {
        guard shouldShowMiniPlayer(currentBookID: currentBookID) else { return }
        isNowPlayingPresented = true
    }
}
