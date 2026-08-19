import SwiftUI

enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}

@MainActor
final class MiniPlayerPresentationRouter: ObservableObject {
    @Published var isNowPlayingPresented = false
    private var pushedPlayerCount = 0

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.isNowPlayingPresented },
            set: { self.isNowPlayingPresented = $0 }
        )
    }

    func playerPushed() { pushedPlayerCount += 1 }
    func playerPopped() { pushedPlayerCount = max(0, pushedPlayerCount - 1) }

    /// Show the miniplayer whenever a playback session exists and neither the
    /// Now Playing sheet nor a pushed BookPageView is visible.
    func shouldShowMiniPlayer(currentBookID: UUID?) -> Bool {
        guard let currentBookID,
              !isNowPlayingPresented,
              pushedPlayerCount == 0 else { return false }
        _ = currentBookID
        return true
    }

    func presentNowPlayingFromMiniPlayer(currentBookID: UUID?) {
        guard shouldShowMiniPlayer(currentBookID: currentBookID) else { return }
        isNowPlayingPresented = true
    }
}
