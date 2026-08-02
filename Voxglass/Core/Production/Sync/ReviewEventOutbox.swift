import Foundation

/// File-backed queue of review events the phone created while CloudKit was
/// unreachable (spec §13.7 retry policy, §14.5 Flow D). Events are append-only and
/// idempotent by their `id`, so a retried push can never duplicate a review action on
/// the Mac. Reuses the existing per-event-file storage pattern from `WatchLink`.
public struct ReviewEventOutbox: Sendable {

    public struct FlushResult: Sendable, Equatable {
        public var pushed: [ReviewEvent]
        public var remaining: [ReviewEvent]

        public init(pushed: [ReviewEvent] = [], remaining: [ReviewEvent] = []) {
            self.pushed = pushed
            self.remaining = remaining
        }
    }

    private let storage: any WatchOutboxStorage

    public init(storage: any WatchOutboxStorage) {
        self.storage = storage
    }

    public func pending() throws -> [ReviewEvent] {
        try storage.read()
    }

    /// Appends an event unless one with the same `id` is already queued.
    public func enqueue(_ event: ReviewEvent) throws {
        var existing = try storage.read()
        if existing.contains(where: { $0.id == event.id }) { return }
        existing.append(event)
        try storage.write(existing)
    }

    /// Pushes all pending events over the transport. On failure nothing is removed,
    /// so the events are retried on the next flush; the Mac's fold dedupes by id.
    public func flush(over engine: ProductionSyncEngine) async throws -> FlushResult {
        let pending = try storage.read()
        guard !pending.isEmpty else { return FlushResult() }
        try await engine.pushEvents(pending)
        try storage.remove(ids: pending.map(\.id))
        return FlushResult(pushed: pending, remaining: [])
    }
}
