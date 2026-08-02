import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ProductionCarPlayBuilderTests {

    private var summaries: [ProjectSummary] {
        ProductionWatchFixtures.summaries()
    }

    @Test func rootTabs_areContinueProductionsReview() {
        let tabs = ProductionCarPlayBuilder.rootTabs(continueSections: [], summaries: summaries)
        #expect(tabs.map(\.title) == ["Continue", "Productions", "Review"])
    }

    @Test func productionsTab_listsSummariesWithFlaggedCounts() {
        let tab = ProductionCarPlayBuilder.productionsTab(summaries: summaries)
        let items = tab.sections.flatMap(\.items)
        #expect(items.count == 1)
        #expect(items.first?.title == ProductionWatchFixtures.rogerAckroydTitle)
        #expect(items.first?.subtitle?.contains("18 flagged") == true)
    }

    @Test func productionsTab_emptyStateWhenNoSummaries() {
        let tab = ProductionCarPlayBuilder.productionsTab(summaries: [])
        #expect(tab.sections.first?.items.first?.id == "empty-productions")
        #expect(tab.sections.first?.items.first?.isEnabled == false)
    }

    @Test func reviewTab_badgesFlaggedTotalAndListsQueues() {
        let tab = ProductionCarPlayBuilder.reviewTab(summaries: summaries)
        #expect(tab.badge == 18)
        let ids = tab.sections.flatMap(\.items).map(\.id)
        #expect(ids.contains("queue-flagged"))
        #expect(ids.contains("queue-pickup"))
        #expect(ids.contains("queue-unapproved"))
        #expect(ids.contains("queue-settings"))
    }

    @Test func queueListSections_markEmptyQueuesDisabled() {
        let sections = ProductionCarPlayBuilder.queueListSections(
            payload: nil,
            flaggedCount: 0,
            pickupCount: 0,
            unapprovedCount: 0
        )
        let items = sections.flatMap(\.items)
        #expect(items.filter(\.isEnabled).count == 1) // settings row only
    }

    @Test func productionDetail_hasPlayWholeBookAndReviewFlagged() {
        let sections = ProductionCarPlayBuilder.productionDetail(summaries[0])
        let items = sections.flatMap(\.items)
        #expect(items.contains { $0.id == "play-whole-book" })
        #expect(items.contains { $0.id == "review-flagged" && $0.isEnabled })
    }

    @Test func queueBrowser_capsAtDrivingLimitAndMarksCurrent() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let sections = ProductionCarPlayBuilder.queueBrowserSections(payload: payload, currentIndex: 3)
        let items = sections.flatMap(\.items)
        #expect(items.count == ProductionCarPlayBuilder.drivingItemCap)
        #expect(items[3].detailText == "Playing")
    }

    @Test func settings_includeSafetyNote() {
        let sections = ProductionCarPlayBuilder.settingsSections(autoAdvance: true, context: false, voiceConfirmations: true)
        let items = sections.flatMap(\.items)
        #expect(items.contains { $0.id == "setting-safety-note" && !$0.isEnabled })
        #expect(items.contains { $0.id == "setting-autoAdvance" && $0.detailText == "On" })
        #expect(items.contains { $0.id == "setting-context" && $0.detailText == "Off" })
    }

    @Test func noteSummary_mapsPayloadFields() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let summary = ProductionCarPlayBuilder.noteSummary(payload: payload, index: 1)
        #expect(summary.chapterLabel == payload.chapterLabels[payload.paragraphIDs[1]])
        #expect(summary.noteText == payload.notes[payload.paragraphIDs[1]])
        #expect(summary.tag == payload.tags[payload.paragraphIDs[1]])
    }

    @Test func confirmation_messageUsesNextParagraph() {
        var session = CarPlayReviewSession(payload: ProductionWatchFixtures.flaggedQueue())
        session.currentIndex = 0
        let confirmation = ProductionCarPlayBuilder.confirmation(command: .approveAndNext, session: session)
        #expect(confirmation.title == "Paragraph Approved")
        #expect(confirmation.nextParagraphLabel != nil)
    }
}

@Suite struct CarPlayReviewSessionTests {

    @Test func initClampsIndexToPayloadBounds() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        #expect(CarPlayReviewSession(payload: payload, currentIndex: 999).currentIndex == 17)
        #expect(CarPlayReviewSession(payload: payload, currentIndex: -3).currentIndex == 0)
    }

    @Test func advanceAndRewindRespectBounds() {
        var session = CarPlayReviewSession(payload: ProductionWatchFixtures.flaggedQueue())
        #expect(session.isAtStart)
        session.advance()
        #expect(session.currentIndex == 1)
        session.rewind()
        #expect(session.isAtStart)
        session.currentIndex = 17
        session.advance()
        #expect(session.isAtEnd)
        #expect(session.nextParagraphLabel == nil)
    }

    @Test func currentFieldsMapThroughPayload() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        #expect(session.currentParagraphID == payload.paragraphIDs[0])
        #expect(session.currentText == payload.texts[payload.paragraphIDs[0]])
        #expect(session.currentTag == payload.tags[payload.paragraphIDs[0]])
    }

    @Test func autoAdvanceDefaultsToPayloadSetting() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        #expect(CarPlayReviewSession(payload: payload).autoAdvance == payload.autoAdvance)
        #expect(CarPlayReviewSession(payload: payload, autoAdvance: false).autoAdvance == false)
    }
}

@Suite struct CarPlayReviewCommandMapperTests {

    private let clockDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let eventID = UUID(uuidString: "0CA6F57D-6B41-4C38-A8F9-00000000C001")!

    private func mapper() -> CarPlayReviewCommandMapper {
        CarPlayReviewCommandMapper()
    }

    @Test func approveAndNext_emitsApproveForCurrentParagraphAndAdvances() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 2)
        let outcome = mapper().outcome(for: .approveAndNext, in: session, eventID: eventID, createdAt: clockDate)

        let event = outcome.event
        #expect(event?.type == .approve)
        #expect(event?.paragraphID == payload.paragraphIDs[2])
        #expect(event?.projectID == payload.projectID)
        #expect(event?.device == .carPlay)
        #expect(event?.id == eventID)
        #expect(event?.createdAt == clockDate)
        #expect(outcome.confirmed)
        #expect(outcome.session.currentIndex == 3)
    }

    @Test func needsPickupAndNext_emitsNeedsPickup() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        let outcome = mapper().outcome(for: .needsPickupAndNext, in: session, eventID: eventID, createdAt: clockDate)
        #expect(outcome.event?.type == .needsPickup)
        #expect(outcome.session.currentIndex == 1)
    }

    @Test func keepFlaggedAndNext_emitsNoEventButAdvances() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        let outcome = mapper().outcome(for: .keepFlaggedAndNext, in: session)
        #expect(outcome.event == nil)
        #expect(outcome.session.currentIndex == 1)
    }

    @Test func playNext_advancesWithoutEvent() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        let outcome = mapper().outcome(for: .playNext, in: session)
        #expect(outcome.event == nil)
        #expect(outcome.session.currentIndex == 1)
    }

    @Test func playNext_atEndStaysPut() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 17)
        let outcome = mapper().outcome(for: .playNext, in: session)
        #expect(outcome.session.currentIndex == 17)
    }

    @Test func undoAfterPickup_emitsClearPickupAndRewinds() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        var session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        session = mapper().outcome(for: .needsPickupAndNext, in: session).session

        let undo = mapper().outcome(for: .undo, in: session, eventID: eventID, createdAt: clockDate)
        #expect(undo.event?.type == .clearPickup)
        #expect(undo.event?.paragraphID == payload.paragraphIDs[0])
        #expect(undo.session.currentIndex == 0)
    }

    @Test func undoAfterApprove_rewindsWithoutEvent() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        var session = CarPlayReviewSession(payload: payload, currentIndex: 0)
        session = mapper().outcome(for: .approveAndNext, in: session).session

        let undo = mapper().outcome(for: .undo, in: session)
        #expect(undo.event == nil)
        #expect(undo.session.currentIndex == 0)
    }

    @Test func undoWithEmptyHistory_isNoOp() {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let session = CarPlayReviewSession(payload: payload, currentIndex: 5)
        let outcome = mapper().outcome(for: .undo, in: session)
        #expect(outcome.event == nil)
        #expect(outcome.session.currentIndex == 5)
    }

    @Test func emptyPayload_producesNoEvent() {
        let payload = ResolvedQueuePayload(projectID: UUID(), projectTitle: "Empty", queueLabel: "Flagged")
        let session = CarPlayReviewSession(payload: payload)
        let outcome = mapper().outcome(for: .approveAndNext, in: session)
        #expect(outcome.event == nil)
        #expect(!outcome.confirmed)
    }
}
