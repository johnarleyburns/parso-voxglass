import Foundation

/// File-backed persistence for review events the watch created while the phone was
/// unreachable. Events are append-only and idempotent by their `id`, so a retry can
/// never duplicate a review action on the Mac.
public protocol WatchOutboxStorage: Sendable {
    func read() throws -> [ReviewEvent]
    func write(_ events: [ReviewEvent]) throws
    func remove(ids: [UUID]) throws
}

/// Default outbox storage: one JSON file per event in a directory, named by event id.
/// Reading is a directory scan, so a partially written event is naturally skipped.
public struct FileWatchOutboxStorage: WatchOutboxStorage {
    public let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
    }

    public func read() throws -> [ReviewEvent] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        var events: [ReviewEvent] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let event = try? decoder.decode(ReviewEvent.self, from: data) else { continue }
            events.append(event)
        }
        return events
    }

    public func write(_ events: [ReviewEvent]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for event in events {
            let url = directory.appendingPathComponent("\(event.id.uuidString).json")
            let data = try encoder.encode(event)
            try data.write(to: url, options: .atomic)
        }
    }

    public func remove(ids: [UUID]) throws {
        for id in ids {
            let url = directory.appendingPathComponent("\(id.uuidString).json")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// The watch's offline review queue. Enqueues locally, flushes over the transport when
/// the phone is reachable, and removes events only after the transport accepts them —
/// so a mid-transfer failure leaves the event in place for the next retry.
///
/// All state lives on disk behind `WatchOutboxStorage`, so this value type is `Sendable`
/// without a lock.
public struct WatchReviewOutbox: Sendable {

    public struct FlushResult: Sendable, Equatable {
        public var transferred: [ReviewEvent]
        public var remaining: [ReviewEvent]
        public init(transferred: [ReviewEvent] = [], remaining: [ReviewEvent] = []) {
            self.transferred = transferred
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

    /// Appends an event unless an event with the same `id` is already queued
    /// (idempotent — the watch may re-request the same save twice).
    public func enqueue(_ event: ReviewEvent) throws {
        var existing = try storage.read()
        if existing.contains(where: { $0.id == event.id }) { return }
        existing.append(event)
        try storage.write(existing)
    }

    /// Transfers all pending events over the transport and removes the transferred
    /// ones from disk. On failure, nothing is removed and the error surfaces so the
    /// caller can present the "saved, will sync" state.
    public func flush(over transport: any WatchTransport) async throws -> FlushResult {
        let pending = try storage.read()
        guard !pending.isEmpty else { return FlushResult() }

        try await transport.sendEvents(pending)
        try storage.remove(ids: pending.map(\.id))
        return FlushResult(transferred: pending, remaining: [])
    }
}

public enum WatchOutboxError: Error, LocalizedError, Equatable {
    case transferFailed(Int, underlying: any Error)

    public static func == (lhs: WatchOutboxError, rhs: WatchOutboxError) -> Bool {
        switch (lhs, rhs) {
        case let (.transferFailed(a, _), .transferFailed(b, _)):
            return a == b
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .transferFailed(count, _):
            return "\(count) review action(s) could not reach the iPhone yet."
        }
    }
}
