import Foundation

/// Applies a stream of review events to a project store, the phone-writer way
/// (spec §4.2): the iPhone folds watch and iPhone review actions into its local
/// `ProductionStore` — there is no second editing surface and no remote fold.
///
/// Idempotent by event id: events are appended with `INSERT OR IGNORE`, the fold
/// is deterministic, and applied events are marked only after the states and
/// notes are written. A crash between any step leaves the events unapplied so the
/// next run re-folds from the current state without duplication.
public struct ProductionReviewEventApplicator: Sendable {
    private let clock: any Clock
    private let folder: ReviewEventFolder

    public init(clock: any Clock = SystemClock(), folder: ReviewEventFolder = ReviewEventFolder()) {
        self.clock = clock
        self.folder = folder
    }

    /// Appends `events`, folds every unapplied event into the current project
    /// state, writes the resulting review states and notes, and marks them
    /// applied. Returns the paragraph IDs whose review state changed so the
    /// caller can re-project and republish the mirror.
    public func apply(events: [ReviewEvent], to store: any ProductionStore) async throws -> Set<UUID> {
        guard !events.isEmpty else { return [] }

        try await store.appendEvents(events)
        let unapplied = try await store.unappliedEvents()
        guard !unapplied.isEmpty else { return [] }

        let project = try await store.load()
        var initial: [UUID: ReviewState] = [:]
        for paragraph in project.allParagraphs {
            initial[paragraph.id] = paragraph.reviewState
        }

        let result = folder.fold(unapplied, into: initial)

        for (paragraphID, state) in result.states {
            try await store.setReviewState(state, forParagraph: paragraphID)
        }
        for note in result.notesToInsert {
            try await store.insertNote(note)
        }

        try await store.markEventsApplied(unapplied.map(\.id), at: clock.now)
        return result.changedParagraphIDs
    }
}
