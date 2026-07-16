import CarPlay
import Combine
import UIKit
import VoxglassCore

/// Keeps `CPNowPlayingTemplate.shared` current: rate / sleep / bookmark custom
/// buttons plus the built-in Up Next button wired to "Chapters"
/// (docs/CARPLAY_DESIGN.md §5.2). Re-reads the pure
/// `CarPlayNowPlayingModel.config(...)` on every coordinator change and
/// re-applies the buttons.
@MainActor
final class CarPlayNowPlayingConfigurator: NSObject {
    private let coordinator: PlaybackCoordinator
    private weak var dispatcher: CarPlayActionDispatcher?
    private var cancellable: AnyCancellable?
    private var lastConfig: CarPlayNowPlayingConfig?

    init(coordinator: PlaybackCoordinator, dispatcher: CarPlayActionDispatcher) {
        self.coordinator = coordinator
        self.dispatcher = dispatcher
        super.init()
        CPNowPlayingTemplate.shared.add(self)
        apply()
        cancellable = coordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.apply()
            }
    }

    deinit {
        MainActor.assumeIsolated {
            CPNowPlayingTemplate.shared.remove(self)
        }
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
        var buttons: [CPNowPlayingButton] = []

        if config.showsRateButton {
            buttons.append(CPNowPlayingPlaybackRateButton { [weak self] _ in
                self?.dispatcher?.cycleRate()
            })
        }

        buttons.append(sleepButton(config: config))

        if config.showsBookmark {
            buttons.append(CPNowPlayingImageButton(
                image: UIImage(systemName: "bookmark") ?? UIImage()
            ) { [weak self] _ in
                self?.dispatcher?.dispatch(.addBookmark)
            })
        }

        template.updateNowPlayingButtons(buttons)
        template.isUpNextButtonEnabled = config.isUpNextChapters
        template.upNextTitle = "Chapters"
    }

    private func sleepButton(config: CarPlayNowPlayingConfig) -> CPNowPlayingButton {
        let symbolName = config.sleepActive ? "moon.fill" : "moon"
        var image = UIImage(systemName: symbolName) ?? UIImage()
        if config.sleepActive {
            image = image.withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        }
        return CPNowPlayingImageButton(image: image) { [weak self] _ in
            self?.dispatcher?.presentSleepSheet()
        }
    }
}

extension CarPlayNowPlayingConfigurator: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            self.dispatcher?.dispatch(.showChapters)
        }
    }
}
