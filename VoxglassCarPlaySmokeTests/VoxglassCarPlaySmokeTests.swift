import CarPlay
import Foundation
import XCTest
@testable import Voxglass
@testable import VoxglassCore

/// Part of the iPhone smoke test (docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md
/// §19.5). CarPlay cannot be driven by XCUITest, so these hosted scene tests run
/// in the same iOS-simulator test action as `VoxglassUITests`
/// (`xcodebuild test -scheme Voxglass`). They never run on GitHub Actions.
final class VoxglassCarPlaySmokeTests: XCTestCase {

    @MainActor
    func testRendererBuildsFiveTabsAndResumeRowFromModel() throws {
        let state = CarPlayState.fixtureWithOneInProgressBook()
        let interface = CarPlayMenuBuilder.root(state)

        let tabBar = CarPlayTemplateRenderer.render(interface,
                                                    dispatcher: .noop,
                                                    artwork: .noop)

        XCTAssertEqual(tabBar.templates.count, 5)
        let continueList = try XCTUnwrap(tabBar.templates.first as? CPListTemplate)
        XCTAssertEqual(continueList.tabTitle, "Continue")
        let firstItem = try XCTUnwrap(continueList.sections.first?.items.first as? CPListItem)
        XCTAssertEqual(firstItem.text, state.recentlyPlayed.first?.title)
        XCTAssertNotNil(firstItem.handler)
    }

    /// Spec §19.5: the production tab bar builds three tabs, the Review tab lists
    /// the seeded queue, approving emits exactly one ReviewEvent per paragraph,
    /// and the remote commands map to paragraph boundaries while the queue is
    /// active — a review-only queue can be completed without touching the phone.
    @MainActor
    func testBuildsProductionTabBar_andApproveEmitsOneEventPerParagraph() throws {
        let env = CarPlayTestEnvironment(seed: .oneFlaggedQueue)
        let controller = CarPlayReviewController(
            dataProvider: env.store,
            eventSink: env.sync,
            player: env.player,
            cuePlayer: env.cuePlayer
        )

        let root = try XCTUnwrap(controller.makeRootTemplate() as? CPTabBarTemplate)
        XCTAssertEqual(root.templates.count, 3) // Continue / Productions / Review
        let review = try XCTUnwrap(root.templates.compactMap { $0 as? CPListTemplate }.first { $0.title == "Review" })
        XCTAssertFalse(review.sections.first?.items.isEmpty ?? true)

        let nowPlaying = controller.startQueue(.flagged)
        XCTAssertTrue(nowPlaying.reviewButtonIDs.contains("carplay.approve"))
        XCTAssertTrue(nowPlaying.reviewButtonIDs.contains("carplay.pickup"))
        XCTAssertTrue(nowPlaying.reviewButtonIDs.contains("carplay.keepFlagged"))

        controller.perform(.approveAndNext)
        XCTAssertEqual(env.sync.emittedEvents.map(\.type), [.approve]) // exactly one
        XCTAssertEqual(env.cuePlayer.playedCues, [.approve])          // exactly one audio confirmation

        controller.perform(.approveAndNext)
        XCTAssertEqual(env.sync.emittedEvents.count, 2)                 // different paragraph, not a duplicate
        XCTAssertEqual(Set(env.sync.emittedEvents.map(\.paragraphID)).count, 2)
        XCTAssertEqual(Set(env.sync.emittedEvents.map(\.device)), [.carPlay])
        XCTAssertEqual(env.cuePlayer.playedCues.count, 2)               // a cue per confirmation

        // The pickup action maps to its own earcon.
        controller.perform(.needsPickupAndNext)
        XCTAssertEqual(env.cuePlayer.playedCues.last, .pickup)

        XCTAssertEqual(controller.remoteCommandMapping, .paragraphBoundaries)
        controller.stop()
        XCTAssertEqual(controller.remoteCommandMapping, .consumer)
    }
}

/// Hosted fakes for the production CarPlay smoke path: preloaded with the
/// `oneFlaggedQueue` seed (18 flagged paragraphs), records every delivered event.
/// `@preconcurrency` relaxes only the Sendable/actor-isolation check on the
/// conformance: these doubles are constructed and read exclusively on the main
/// actor by the hosted tests, so the relaxed checking is safe.
@MainActor
final class CarPlayTestEnvironment {

    enum Seed {
        case oneFlaggedQueue
    }

    let store: CarPlayTestStore
    let sync: CarPlayTestSync
    let player: CarPlayTestPlayer
    let cuePlayer: CarPlayTestCuePlayer

    init(seed: Seed) {
        switch seed {
        case .oneFlaggedQueue:
            let fixture = ProductionWatchFixtures.watchQueueSeed()
            store = CarPlayTestStore(summaries: fixture.summaries, queue: fixture.queue)
            sync = CarPlayTestSync()
            player = CarPlayTestPlayer()
            cuePlayer = CarPlayTestCuePlayer()
        }
    }
}

@MainActor
final class CarPlayTestStore: @preconcurrency CarPlayProductionDataProviding {
    private let summaries: [ProjectSummary]
    private let queue: ResolvedQueuePayload

    init(summaries: [ProjectSummary], queue: ResolvedQueuePayload) {
        self.summaries = summaries
        self.queue = queue
    }

    func productionSummaries() -> [ProjectSummary] { summaries }

    func queuePayload(_ type: ProductionQueueType) -> ResolvedQueuePayload? {
        type == .flagged ? queue : nil
    }
}

@MainActor
final class CarPlayTestSync: @preconcurrency CarPlayEventDelivering {
    private(set) var emittedEvents: [ReviewEvent] = []

    func send(_ events: [ReviewEvent]) throws {
        emittedEvents.append(contentsOf: events)
    }
}

@MainActor
final class CarPlayTestPlayer: CarPlayProductionPlaying {
    private(set) var playedParagraphIDs: [UUID] = []

    func play(paragraphID: UUID, in payload: ResolvedQueuePayload) async {
        playedParagraphIDs.append(paragraphID)
    }

    func pause() async {}
}

/// Records every confirmation earcon the controller asks for (§18.3 rule 6).
@MainActor
final class CarPlayTestCuePlayer: @preconcurrency CarPlayCuePlaying {
    private(set) var playedCues: [CarPlayCueKind] = []

    func play(_ cue: CarPlayCueKind) {
        playedCues.append(cue)
    }
}
