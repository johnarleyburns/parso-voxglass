import SwiftUI
import Observation
import VoxglassCore

enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}

@MainActor
@Observable
final class MiniPlayerPresentationRouter {
    private var state = NowPlayingPresentationState()
    private var pushedPlayerCount = 0

    var isNowPlayingPresented: Bool { state.isNowPlayingPresented }
    var pendingNowPlayingBookID: UUID? { state.pendingBookID }

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.state.isNowPlayingPresented },
            set: { self.state.setPresented($0) }
        )
    }

    /// Navigation-only dismissal; never stops or mutates playback.
    func dismissNowPlayingForNavigation() {
        state.setPresented(false)
    }

    func requestNowPlayingAfterSelection(bookID: UUID) {
        state.requestPresentation(for: bookID)
    }

    /// Called by the root when the coordinator publishes a session.
    @discardableResult
    func presentWhenSessionIsReady(bookID: UUID?) -> Bool {
        state.consumeReadySession(bookID: bookID)
    }

    func cancelPendingNowPlaying() { state.cancelPending() }

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
        state.setPresented(true)
    }
}
