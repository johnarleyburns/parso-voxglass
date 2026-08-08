import Foundation

/// Applies fetched review events to a store and decides whether to republish.
/// The fold semantics live in `ReviewEventFolder` (§14.2). The phone as the sole
/// writer folds watch/iPhone events into its local project store through
/// `ProductionReviewEventApplicator`; this ingestor is the retained generic
/// fetch→dedupe→append→fold loop for a caller that supplies its own sink.
public protocol ProductionEventSink: Sendable {
    /// Appends events idempotently (`INSERT OR IGNORE` by event id), folds the newly
    /// applied events, and returns the paragraph IDs whose review state changed.
    func apply(events: [ReviewEvent]) async throws -> Set<UUID>

    /// Called after applying when review state changed; the caller republishes so
    /// other devices see the new state (§14.5 Flow A step 4).
    func republishAfterReviewChange(changedParagraphIDs: Set<UUID>) async
}

/// Event ingestion (spec §13.7): fetch → dedupe → append → fold → delete
/// consumed event records → republish if any review state changed. The dedupe/append/
/// fold step is performed by the injected `ProductionEventSink`; `sinkProvider`
/// returns the sink for the currently open project (the store changes per project).
public actor EventIngestor {

    private let engine: ProductionSyncEngine
    private let sinkProvider: @Sendable () async -> (any ProductionEventSink)?

    public init(
        engine: ProductionSyncEngine,
        sinkProvider: @escaping @Sendable () async -> (any ProductionEventSink)?
    ) {
        self.engine = engine
        self.sinkProvider = sinkProvider
    }

    public func pump() async throws -> IngestReport {
        let report = try await engine.pump()
        guard let sink = await sinkProvider() else { return report }

        if !report.events.isEmpty {
            let changed = try await sink.apply(events: report.events)
            if !report.eventRecordNames.isEmpty {
                try await engine.deleteConsumedEvents(report.eventRecordNames)
            }
            if !changed.isEmpty {
                await sink.republishAfterReviewChange(changedParagraphIDs: changed)
            }
        }

        return report
    }
}
