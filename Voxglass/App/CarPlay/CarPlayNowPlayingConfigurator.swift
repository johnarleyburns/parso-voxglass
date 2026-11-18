import CarPlay
import Observation
import UIKit
import VoxglassCore

/// Keeps the built-in Up Next button wired to Chapters and clears custom
/// Now Playing buttons. CarPlay owns the transport and progress layout.
@MainActor
final class CarPlayNowPlayingConfigurator: NSObject {
    private let coordinator: PlaybackCoordinator
    private weak var dispatcher: CarPlayActionDispatcher?
    private var subscription: ObservationSubscription?
    private var lastConfig: CarPlayNowPlayingConfig?

    init(coordinator: PlaybackCoordinator, dispatcher: CarPlayActionDispatcher) {
        self.coordinator = coordinator
        self.dispatcher = dispatcher
        super.init()
        CPNowPlayingTemplate.shared.add(self)
        apply()

        subscription = ObservationSubscription(
            track: { [coordinator] in
                // Track only the properties the config actually depends on.
                _ = coordinator.currentSession?.book.id
                _ = coordinator.currentSession?.chapter.id
                _ = coordinator.currentSession?.isPlaying
                _ = coordinator.playbackRate
                _ = coordinator.sleepMode
                _ = coordinator.sleepDisplayMinute
                _ = coordinator.bookmarkCount
            },
            onChange: { [weak self] in
                self?.apply()
            }
        )
    }

    deinit {
    }

    private func apply() {
        let session = coordinator.currentSession
        let config = CarPlayNowPlayingModel.config(
            hasSession: session != nil,
            chapterCount: session?.chapters.count ?? 0,
            rate: coordinator.playbackRate,
            sleepMode: coordinator.sleepMode,
            sleepRemaining: coordinator.sleepRemaining,
            hasBookmarkStore: coordinator.bookmarkStore != nil
        )
        guard config != lastConfig else { return }
        lastConfig = config

        let template = CPNowPlayingTemplate.shared
        template.updateNowPlayingButtons([])
        template.isUpNextButtonEnabled = config.isUpNextChapters
        template.upNextTitle = String(localized: "Chapters")
    }

}

extension CarPlayNowPlayingConfigurator: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            self.dispatcher?.dispatch(.showChapters)
        }
    }
}
