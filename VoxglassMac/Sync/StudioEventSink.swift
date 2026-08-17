import Foundation
import VoxglassCore

/// The Mac's `ProductionEventSink`: appends fetched review events idempotently
/// (`INSERT OR IGNORE` by event id), folds the newly applied events into review
/// state, applies the fold in one pass, and reports which paragraphs changed so the
/// coordinator can republish (spec §13.7, §14.2).
public final class StudioEventSink: ProductionEventSink, @unchecked Sendable {

    private let store: any ProductionStore
    private let folder: ReviewEventFolder
    private let clock: any Clock

    public init(store: any ProductionStore, clock: any Clock = SystemClock()) {
        self.store = store
        self.folder = ReviewEventFolder()
        self.clock = clock
    }

    public func apply(events: [ReviewEvent]) async throws -> Set<UUID> {
        try await store.appendEvents(events)
        let unapplied = try await store.unappliedEvents()
        guard !unapplied.isEmpty else { return [] }

        let current = try await currentReviewStates(for: unapplied)
        let result = folder.fold(unapplied, into: current)

        for (paragraphID, state) in result.states where state != current[paragraphID] {
            try await store.setReviewState(state, forParagraph: paragraphID)
        }
        for note in result.notesToInsert {
            try await store.insertNote(note)
        }
        try await store.markEventsApplied(unapplied.map(\.id), at: clock.now)

        return result.changedParagraphIDs
    }

    public func republishAfterReviewChange(changedParagraphIDs: Set<UUID>) async {
        // Wired by the coordinator after init; see `onReviewStateChanged`.
    }

    public var onReviewStateChanged: (@Sendable (Set<UUID>) async -> Void)?

    private func currentReviewStates(for events: [ReviewEvent]) async throws -> [UUID: ReviewState] {
        let project = try await store.load()
        let states = project.allParagraphs.reduce(into: [UUID: ReviewState]()) { $0[$1.id] = $1.reviewState }
        // Missing paragraphs (deleted locally) default to unreviewed.
        return events.reduce(into: states) { result, event in
            if result[event.paragraphID] == nil { result[event.paragraphID] = .unreviewed }
        }
    }
}
