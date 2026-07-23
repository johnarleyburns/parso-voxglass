import SwiftUI

enum BookPagePresentationContext {
    case pushedDetail
    case nowPlayingSheet
}

@MainActor
final class MiniPlayerPresentationRouter: ObservableObject {
    @Published var isNowPlayingPresented = false
    @Published private(set) var visiblePushedBookID: UUID?

    func bindNowPlaying() -> Binding<Bool> {
        Binding(
            get: { self.isNowPlayingPresented },
            set: { self.isNowPlayingPresented = $0 }
        )
    }

    func registerPushedBookPage(_ id: UUID) {
        visiblePushedBookID = id
    }

    func unregisterPushedBookPage(_ id: UUID) {
        if visiblePushedBookID == id {
            visiblePushedBookID = nil
        }
    }

    func shouldShowMiniPlayer(currentBookID: UUID?) -> Bool {
        guard let currentBookID, !isNowPlayingPresented else { return false }
        return visiblePushedBookID != currentBookID
    }

    func presentNowPlayingFromMiniPlayer(currentBookID: UUID?) {
        guard shouldShowMiniPlayer(currentBookID: currentBookID) else { return }
        isNowPlayingPresented = true
    }
}
