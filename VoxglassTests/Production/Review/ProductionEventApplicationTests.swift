import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

/// The phone-writer fold (§4.2): `ProductionReviewEventApplicator` applies watch
/// and iPhone review events into the local project store, idempotently by event
/// id, and reports which paragraph states changed so the caller republishes.
@Suite struct ProductionEventApplicationTests {

    private let clock = FixedClock()

    private func makeStore(project: AudiobookProject) async throws -> InMemoryProductionStore {
        let store = InMemoryProductionStore()
        try await store.save(project)
        return store
    }

    private func event(
        projectID: UUID,
        paragraphID: UUID,
        type: ReviewEventType,
        note: String? = nil,
        at time: TimeInterval
    ) -> ReviewEvent {
        ReviewEvent(
            id: UUID(),
            projectID: projectID,
            paragraphID: paragraphID,
            type: type,
            noteText: note,
            device: .watch,
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    /// A single flag folds into the project's review state and returns the
    /// changed paragraph id.
    @Test func apply_foldsStateIntoStore() async throws {
        let project = ProjectFixtures.tiny()
        let store = try await makeStore(project: project)
        let paragraphID = project.allParagraphs[0].id

        let changed = try await ProductionReviewEventApplicator(clock: clock).apply(
            events: [event(projectID: project.id, paragraphID: paragraphID, type: .flag, at: 1_700_000_000)],
            to: store
        )

        #expect(changed == [paragraphID])
        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first { $0.id == paragraphID }?.reviewState == .flagged)
        #expect(try await store.unappliedEvents().isEmpty)
    }

    /// A sequence flag → note → approve yields one final state and exactly one
    /// note (the fold's `addNote` also flags an unreviewed paragraph).
    @Test func apply_foldsSequenceToFinalState() async throws {
        let project = ProjectFixtures.tiny()
        let store = try await makeStore(project: project)
        let paragraphID = project.allParagraphs[0].id
        let applicator = ProductionReviewEventApplicator(clock: clock)

        let events = [
            event(projectID: project.id, paragraphID: paragraphID, type: .flag, at: 1_700_000_000),
            event(projectID: project.id, paragraphID: paragraphID, type: .addNote, note: "Breath here", at: 1_700_000_001),
            event(projectID: project.id, paragraphID: paragraphID, type: .approve, at: 1_700_000_002)
        ]
        let changed = try await applicator.apply(events: events, to: store)

        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first { $0.id == paragraphID }?.reviewState == .approved)
        #expect(changed.contains(paragraphID))
        let notes = try await store.notes(forParagraph: paragraphID)
        #expect(notes.count == 1)
        #expect(notes[0].text == "Breath here")
    }

    /// Re-applying the same events (a retried delivery) changes nothing and
    /// produces no duplicate notes — idempotent by event id.
    @Test func apply_isIdempotentAcrossRetries() async throws {
        let project = ProjectFixtures.tiny()
        let store = try await makeStore(project: project)
        let paragraphID = project.allParagraphs[0].id
        let applicator = ProductionReviewEventApplicator(clock: clock)

        let events = [
            event(projectID: project.id, paragraphID: paragraphID, type: .flag, at: 1_700_000_000),
            event(projectID: project.id, paragraphID: paragraphID, type: .addNote, note: "Check level", at: 1_700_000_001)
        ]

        let first = try await applicator.apply(events: events, to: store)
        #expect(first.contains(paragraphID))

        let second = try await applicator.apply(events: events, to: store)
        #expect(second.isEmpty)

        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first { $0.id == paragraphID }?.reviewState == .flagged)
        #expect(try await store.notes(forParagraph: paragraphID).count == 1)
        #expect(try await store.unappliedEvents().isEmpty)
    }

    /// The fold starts from the project's current state: an event that repeats a
    /// state already applied reports no change and does not touch the note list.
    @Test func apply_respectsCurrentProjectState() async throws {
        let project = ProjectFixtures.tiny()
        var flaggedProject = project
        let paragraphID = project.allParagraphs[0].id
        flaggedProject.chapters[0].paragraphs[0].reviewState = .approved
        let store = try await makeStore(project: flaggedProject)

        let changed = try await ProductionReviewEventApplicator(clock: clock).apply(
            events: [event(projectID: project.id, paragraphID: paragraphID, type: .approve, at: 1_700_000_000)],
            to: store
        )

        #expect(changed.isEmpty)
        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first { $0.id == paragraphID }?.reviewState == .approved)
    }
}
