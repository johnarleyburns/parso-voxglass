import CarPlay
import Foundation
import MediaPlayer
import VoxglassCore

/// The single controller for the CarPlay production surface: builds the 3-tab
/// root (Continue / Productions / Review), runs review queues in the now-playing
/// template, maps every command to a `ReviewEvent` through
/// `CarPlayReviewCommandMapper`, and switches the system next/prev-track remote
/// commands to paragraph boundaries while a queue is active (spec §18.3 rules 3
/// and 7). Host-testable: the smoke test drives it with a fake data provider,
/// event sink, and player, and no car.
@MainActor
public final class CarPlayReviewController {

    public private(set) var remoteCommandMapping: RemoteCommandMapping = .consumer
    public private(set) var summaries: [ProjectSummary] = []
    public private(set) var session: CarPlayReviewSession?
    public private(set) var lastEventError: String?

    public var autoAdvance = true
    public var playContext = false
    public var voiceConfirmations = true

    private let dataProvider: any CarPlayProductionDataProviding
    private let eventSink: any CarPlayEventDelivering
    private let player: any CarPlayProductionPlaying
    private let cuePlayer: any CarPlayCuePlaying
    private weak var interfaceController: CPInterfaceController?
    private let continueProvider: () -> [CarPlaySection]
    private let mapper = CarPlayReviewCommandMapper()

    public init(
        dataProvider: any CarPlayProductionDataProviding,
        eventSink: any CarPlayEventDelivering,
        player: any CarPlayProductionPlaying,
        cuePlayer: (any CarPlayCuePlaying)? = nil,
        interfaceController: CPInterfaceController? = nil,
        continueProvider: @escaping () -> [CarPlaySection] = { [] }
    ) {
        self.dataProvider = dataProvider
        self.eventSink = eventSink
        self.player = player
        self.cuePlayer = cuePlayer ?? BundledCarPlayCuePlayer()
        self.interfaceController = interfaceController
        self.continueProvider = continueProvider
        self.summaries = dataProvider.productionSummaries()
    }

    // MARK: - Root

    public func makeRootTemplate() -> CPTabBarTemplate {
        ProductionCarPlayRenderer.tabBar(
            tabs: ProductionCarPlayBuilder.rootTabs(
                continueSections: continueProvider(),
                summaries: summaries
            ),
            handler: { [weak self] action in self?.handle(action) }
        )
    }

    public func refreshSummaries() {
        summaries = dataProvider.productionSummaries()
    }

    // MARK: - Queue

    /// Starts a review queue for the given type and returns the now-playing
    /// session (template + review button identifiers) so tests can assert on it.
    public func startQueue(_ type: ProductionQueueType) -> CarPlayNowPlayingSession {
        guard let payload = dataProvider.queuePayload(type) else {
            return CarPlayNowPlayingSession(template: CPNowPlayingTemplate.shared, reviewButtonIDs: [])
        }
        var initial = CarPlayReviewSession(payload: payload)
        initial.autoAdvance = autoAdvance
        session = initial
        remoteCommandMapping = .paragraphBoundaries
        installParagraphCommands()

        let (template, ids) = ProductionCarPlayRenderer.nowPlayingTemplate(
            reviewButtonIDs: [
                (CarPlayReviewButtonID.keepFlagged, UIImage(systemName: "flag.fill")!),
                (CarPlayReviewButtonID.approve, UIImage(systemName: "checkmark.circle.fill")!),
                (CarPlayReviewButtonID.pickup, UIImage(systemName: "arrow.triangle.2.circlepath")!)
            ],
            handler: { [weak self] command in self?.perform(command) }
        )
        updateNowPlayingInfo(paragraphLabel: payload.chapterLabels[payload.paragraphIDs[0]] ?? "Paragraph")

        if let interfaceController {
            interfaceController.presentTemplate(template, animated: true, completion: nil)
        }
        Task { await player.play(paragraphID: payload.paragraphIDs[0], in: payload) }
        return CarPlayNowPlayingSession(template: template, reviewButtonIDs: ids)
    }

    /// Maps the command to a `ReviewEvent`, delivers it to the phone outbox,
    /// advances the queue, and (for confirmed actions) presents the confirmation
    /// alert with Play Next / Undo.
    public func perform(_ command: CarPlayReviewCommand) {
        guard var current = session else { return }
        let outcome = mapper.outcome(for: command, in: current)
        session = outcome.session
        current = outcome.session

        if let event = outcome.event {
            do {
                try eventSink.send([event])
                lastEventError = nil
            } catch {
                lastEventError = error.localizedDescription
            }
        }

        // Audio confirmations: a short earcon per review action (§18.3 rule 6).
        if voiceConfirmations, let cue = outcome.cue {
            cuePlayer.play(cue)
        }

        if let paragraphID = current.currentParagraphID {
            updateNowPlayingInfo(paragraphLabel: current.currentChapterLabel ?? "Paragraph")
            Task { await player.play(paragraphID: paragraphID, in: current.payload) }
        }

        if outcome.confirmed {
            let confirmation = ProductionCarPlayBuilder.confirmation(command: command, session: current)
            presentConfirmation(confirmation)
        }
    }

    public func stop() {
        session = nil
        remoteCommandMapping = .consumer
        uninstallParagraphCommands()
        Task { await player.pause() }
    }

    // MARK: - Navigation (pushed templates)

    public func openQueueBrowser() {
        guard let session else { return }
        let template = ProductionCarPlayRenderer.listTemplate(
            title: "\(session.payload.queueLabel) Queue",
            sections: ProductionCarPlayBuilder.queueBrowserSections(
                payload: session.payload,
                currentIndex: session.currentIndex
            ),
            handler: { [weak self] action in self?.handle(action) }
        )
        push(template)
    }

    public func openNoteSummary() {
        guard let session else { return }
        let summary = ProductionCarPlayBuilder.noteSummary(
            payload: session.payload,
            index: session.currentIndex
        )
        push(ProductionCarPlayRenderer.noteSummaryTemplate(summary))
    }

    public func openSettings() {
        let template = ProductionCarPlayRenderer.listTemplate(
            title: "Review Settings",
            sections: ProductionCarPlayBuilder.settingsSections(
                autoAdvance: autoAdvance,
                context: playContext,
                voiceConfirmations: voiceConfirmations
            ),
            handler: { [weak self] action in self?.handle(action) }
        )
        push(template)
    }

    // MARK: - Actions

    private func handle(_ action: ProductionCarPlayAction) {
        switch action {
        case .openProduction(let id):
            guard let summary = summaries.first(where: { $0.id == id }) else { return }
            let template = ProductionCarPlayRenderer.listTemplate(
                title: summary.title,
                sections: ProductionCarPlayBuilder.productionDetail(summary),
                handler: { [weak self] action in self?.handle(action) }
            )
            push(template)

        case .startQueue(let type):
            _ = startQueue(type)

        case .openQueueBrowser:
            openQueueBrowser()

        case .openNoteSummary:
            openNoteSummary()

        case .openSettings:
            openSettings()

        case .playNext:
            perform(.playNext)

        case .undo:
            perform(.undo)

        case .playWholeBook, .none:
            break

        case .toggleAutoAdvance:
            autoAdvance.toggle()

        case .toggleContext:
            playContext.toggle()

        case .toggleVoiceConfirmations:
            voiceConfirmations.toggle()
        }
    }

    private func push(_ template: CPTemplate) {
        guard let interfaceController else { return }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func presentConfirmation(_ confirmation: ProductionCarPlayConfirmation) {
        guard let interfaceController else { return }
        let alert = ProductionCarPlayRenderer.confirmationAlert(
            confirmation,
            playNext: { [weak self] in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                self?.perform(.playNext)
            },
            undo: { [weak self] in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                self?.perform(.undo)
            }
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func updateNowPlayingInfo(paragraphLabel: String) {
        guard let session else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: paragraphLabel,
            MPMediaItemPropertyArtist: session.payload.projectTitle
        ]
    }

    // MARK: - Remote commands (paragraph boundaries while queue active)

    private func installParagraphCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        paragraphNextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.remoteCommandMapping == .paragraphBoundaries else { return .commandFailed }
            self.perform(.playNext)
            return .success
        }
        paragraphPreviousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.remoteCommandMapping == .paragraphBoundaries, !(self.session?.isAtStart ?? true) else {
                return .commandFailed
            }
            self.perform(.undo)
            return .success
        }
    }

    private func uninstallParagraphCommands() {
        let center = MPRemoteCommandCenter.shared()
        if let paragraphNextTarget {
            center.nextTrackCommand.removeTarget(paragraphNextTarget)
        }
        if let paragraphPreviousTarget {
            center.previousTrackCommand.removeTarget(paragraphPreviousTarget)
        }
        paragraphNextTarget = nil
        paragraphPreviousTarget = nil
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private var paragraphNextTarget: Any?
    private var paragraphPreviousTarget: Any?
}

/// The now-playing surface returned by `startQueue` — the template plus the
/// identifiers of the custom review buttons, which the smoke test asserts on.
@MainActor
public struct CarPlayNowPlayingSession {
    public let template: CPNowPlayingTemplate
    public let reviewButtonIDs: [String]

    public init(template: CPNowPlayingTemplate, reviewButtonIDs: [String]) {
        self.template = template
        self.reviewButtonIDs = reviewButtonIDs
    }
}
