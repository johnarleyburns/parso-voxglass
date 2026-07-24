import SwiftUI

enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}

@MainActor
final class MiniPlayerPresentationRouter: ObservableObject {
    @Published var isNowPlayingPresented = false

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.isNowPlayingPresented },
            set: { self.isNowPlayingPresented = $0 }
        )
    }

    /// Show the miniplayer whenever a playback session exists and Now Playing
    /// is not presented. Visibility is deterministic — no lifecycle callbacks.
    func shouldShowMiniPlayer(currentBookID: UUID?) -> Bool {
        guard let currentBookID, !isNowPlayingPresented else { return false }
        return true
    }

    func presentNowPlayingFromMiniPlayer(currentBookID: UUID?) {
        guard shouldShowMiniPlayer(currentBookID: currentBookID) else { return }
        isNowPlayingPresented = true
    }
}
