import Foundation

/// iPhone-side mirror coordinator (spec §5). Debounces non-manual triggers to at
/// most one publish per `debounceInterval`, and delegates the delta publish to the
/// shared engine. Manual and app-backgrounded reasons publish immediately.
public actor ProjectionPublisher {

    private let engine: ProductionSyncEngine
    private let debounceInterval: TimeInterval
    private let clock: any Clock
    private var lastPublishDate: Date?

    public init(
        engine: ProductionSyncEngine,
        debounceInterval: TimeInterval = 20,
        clock: any Clock = SystemClock()
    ) {
        self.engine = engine
        self.debounceInterval = debounceInterval
        self.clock = clock
    }

    public func publishIfNeeded(
        reason: PublishReason,
        project: AudiobookProject,
        counts: ProjectCounts,
        watchPinnedParagraphIDs: [UUID] = [],
        latestNotes: [UUID: ReviewNote] = [:]
    ) async throws -> PublishOutcome {
        if reason != .manual && reason != .appBackgrounded {
            let now = clock.now
            if let last = lastPublishDate, now.timeIntervalSince(last) < debounceInterval {
                return .skipped(reason: "debounced")
            }
        }

        let outcome = try await engine.publish(
            project: project,
            counts: counts,
            watchPinnedParagraphIDs: watchPinnedParagraphIDs,
            latestNotes: latestNotes
        )
        switch outcome {
        case .published, .withdrawn:
            lastPublishDate = clock.now
        default:
            break
        }
        return outcome
    }
}
