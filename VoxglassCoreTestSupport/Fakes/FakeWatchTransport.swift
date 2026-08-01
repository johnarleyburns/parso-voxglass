import Foundation
import VoxglassCore

/// Deterministic, inspectable `WatchTransport` for tests. Records every call so
/// assertions can check what was sent, and can be configured to fail on demand —
/// the two behaviors the spec's error-path tests need (§19.2).
public final class FakeWatchTransport: WatchTransport, @unchecked Sendable {

    public enum FailPoint: Sendable {
        case none
        case nextSendSummaries
        case nextSendActiveQueue
        case nextSendAudio
        case nextSendArtwork
        case nextSendEvents
        case nextRequestRefresh
    }

    private let lock = NSLock()
    public var isReachable: Bool
    public var activationState: WatchLinkState
    public var failPoint: FailPoint

    public private(set) var sentSummaries: [ProjectSummary] = []
    public private(set) var sentQueues: [ResolvedQueuePayload] = []
    public private(set) var sentAudio: [[WatchAudioItem]] = []
    public private(set) var sentArtwork: [[UUID: Data]] = []
    public private(set) var sentEvents: [ReviewEvent] = []
    public private(set) var refreshRequests = 0

    /// Events the fake surfaces on `receiveEvents()` (simulating the phone side
    /// receiving what the watch transferred).
    public var receivedEvents: [ReviewEvent] = []

    private let eventContinuation: AsyncStream<ReviewEvent>.Continuation
    public let eventStream: AsyncStream<ReviewEvent>

    public init(
        isReachable: Bool = true,
        activationState: WatchLinkState = .reachable,
        failPoint: FailPoint = .none
    ) {
        self.isReachable = isReachable
        self.activationState = activationState
        self.failPoint = failPoint
        var continuation: AsyncStream<ReviewEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    /// Relays events into the stream (phone side) / records watch-sent events.
    public func receiveEvents() -> AsyncStream<ReviewEvent> {
        eventStream
    }

    public func sendSummaries(_ summaries: [ProjectSummary]) async throws {
        try consumeFailPointIfSet(.nextSendSummaries)
        locked { self.sentSummaries = summaries }
    }

    public func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws {
        try consumeFailPointIfSet(.nextSendActiveQueue)
        locked { self.sentQueues.append(payload) }
    }

    public func sendAudio(_ items: [WatchAudioItem]) async throws {
        try consumeFailPointIfSet(.nextSendAudio)
        locked { self.sentAudio.append(items) }
    }

    public func sendArtwork(_ artwork: [UUID: Data]) async throws {
        try consumeFailPointIfSet(.nextSendArtwork)
        locked { self.sentArtwork.append(artwork) }
    }

    public func sendEvents(_ events: [ReviewEvent]) async throws {
        try consumeFailPointIfSet(.nextSendEvents)
        let snapshot = locked { () -> [ReviewEvent] in
            self.sentEvents.append(contentsOf: events)
            self.receivedEvents.append(contentsOf: events)
            return events
        }
        for event in snapshot {
            eventContinuation.yield(event)
        }
    }

    public func requestRefresh() async throws {
        try consumeFailPointIfSet(.nextRequestRefresh)
        locked { self.refreshRequests += 1 }
    }

    /// Thread-safe snapshot for assertions.
    public func snapshot() -> (
        summaries: [ProjectSummary],
        queues: [ResolvedQueuePayload],
        audio: [[WatchAudioItem]],
        events: [ReviewEvent],
        refreshes: Int
    ) {
        locked { (self.sentSummaries, self.sentQueues, self.sentAudio, self.sentEvents, self.refreshRequests) }
    }

    private func consumeFailPointIfSet(_ point: FailPoint) throws {
        lock.lock()
        let isSet = failPoint == point
        if isSet { failPoint = .none }
        lock.unlock()
        if isSet { throw FakeWatchTransportError.failed }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public enum FakeWatchTransportError: Error, LocalizedError, Equatable {
    case failed
    public var errorDescription: String? { "FakeWatchTransport failed as configured." }
}
