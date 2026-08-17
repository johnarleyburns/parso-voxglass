import Foundation
import Testing
@testable import VoxglassStudioKit
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

/// The Mac side of "offline review notes sync exactly once": the `StudioEventSink`
/// appends fetched events idempotently, folds them, and never double-applies.
@Suite struct StudioEventSinkTests {

    private func makeStore() async throws -> (InMemoryProductionStore, AudiobookProject, UUID) {
        let project = ProjectFixtures.tiny()
        let store = InMemoryProductionStore()
        try await store.save(project)
        let paragraphID = project.allParagraphs[0].id
        return (store, project, paragraphID)
    }

    private func event(_ paragraphID: UUID, _ type: ReviewEventType, at time: TimeInterval = 1_700_000_000) -> ReviewEvent {
        ReviewEvent(
            id: UUID(),
            projectID: paragraphID,
            paragraphID: paragraphID,
            type: type,
            device: .iPhone,
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    @Test func foldAppliesOfflineSequenceExactlyOnce() async throws {
        let (store, _, paragraphID) = try await makeStore()
        let sink = StudioEventSink(store: store, clock: FixedClock())

        var note = event(paragraphID, .addNote, at: 1_700_000_001)
        note.noteText = "Breath here"
        let events = [event(paragraphID, .flag), note, event(paragraphID, .approve, at: 1_700_000_002)]

        let changed = try await sink.apply(events: events)
        #expect(changed == [paragraphID])

        let project = try await store.load()
        #expect(project.allParagraphs[0].reviewState == .approved)
        #expect(try await store.notes(forParagraph: paragraphID).count == 1)
        #expect(try await store.notes(forParagraph: paragraphID)[0].text == "Breath here")

        // A retried push re-delivers the same event ids: the store dedupes them, so
        // nothing is folded twice and no second note is created.
        let again = try await sink.apply(events: events)
        #expect(again.isEmpty)
        #expect(try await store.notes(forParagraph: paragraphID).count == 1)
    }

    @Test func pickupSticksOverApproveAcrossDevices() async throws {
        let (store, _, paragraphID) = try await makeStore()
        let sink = StudioEventSink(store: store, clock: FixedClock())

        // A driver approves, then a pick-up lands within the 60 s window.
        let approve = event(paragraphID, .approve, at: 1_700_000_000)
        let pickup = ReviewEvent(
            id: UUID(), projectID: paragraphID, paragraphID: paragraphID,
            type: .needsPickup, device: .watch,
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        _ = try await sink.apply(events: [approve, pickup])

        let project = try await store.load()
        #expect(project.allParagraphs[0].reviewState == .needsPickup)
    }
}
