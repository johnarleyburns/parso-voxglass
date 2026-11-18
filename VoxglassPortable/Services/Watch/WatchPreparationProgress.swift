import Foundation

/// Typed Watch-preparation progress event for one book.
public struct WatchPreparationProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case downloading, preparing, transcoding, committing, failed, complete
    }

    public let bookID: UUID
    public let phase: Phase
    public let completed: Int
    public let total: Int
    public let detail: String?

    public init(bookID: UUID, phase: Phase, completed: Int, total: Int, detail: String? = nil) {
        self.bookID = bookID
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
    }

    public var isTerminal: Bool { phase == .failed || phase == .complete }
}

/// Limits intermediate UI publications to `maxUpdatesPerSecond` per book.
/// First events, phase changes and terminal events publish immediately; other
/// events are held, the latest wins, and a scheduled trailing flush publishes it.
@MainActor
public final class WatchPreparationProgressCoalescer {
    public typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never>

    private struct BookState {
        var lastPublished: WatchPreparationProgress
        var lastPublishedAt: Date
        var pending: WatchPreparationProgress?
        var flushTask: Task<Void, Never>?
    }

    private let clock: any Clock
    private let minInterval: TimeInterval
    private let scheduler: Scheduler
    private let publish: @MainActor (WatchPreparationProgress) -> Void
    private let publishCancelled: @MainActor (UUID) -> Void
    private var states: [UUID: BookState] = [:]

    public init(
        clock: any Clock = SystemClock(),
        maxUpdatesPerSecond: Double = 4,
        scheduler: Scheduler? = nil,
        publish: @escaping @MainActor (WatchPreparationProgress) -> Void,
        publishCancelled: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.clock = clock
        self.minInterval = 1.0 / maxUpdatesPerSecond
        self.scheduler = scheduler ?? { delay, action in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                action()
            }
        }
        self.publish = publish
        self.publishCancelled = publishCancelled
    }

    public func submit(_ event: WatchPreparationProgress) {
        let now = clock.now
        guard var state = states[event.bookID] else {
            states[event.bookID] = BookState(lastPublished: event, lastPublishedAt: now)
            publish(event)
            return
        }
        if event.phase != state.lastPublished.phase || event.isTerminal {
            state.flushTask?.cancel()
            state.flushTask = nil
            state.pending = nil
            state.lastPublished = event
            state.lastPublishedAt = now
            if event.isTerminal { states[event.bookID] = nil } else { states[event.bookID] = state }
            publish(event)
            return
        }
        let elapsed = now.timeIntervalSince(state.lastPublishedAt)
        if elapsed >= minInterval {
            state.flushTask?.cancel()
            state.flushTask = nil
            state.pending = nil
            state.lastPublished = event
            state.lastPublishedAt = now
            states[event.bookID] = state
            publish(event)
            return
        }
        state.pending = event
        if state.flushTask == nil {
            let id = event.bookID
            state.flushTask = scheduler(minInterval - elapsed) { [weak self] in self?.flush(bookID: id) }
        }
        states[event.bookID] = state
    }

    /// Publishes the held event for `bookID`, if any.
    public func flush(bookID: UUID) {
        guard var state = states[bookID] else { return }
        state.flushTask = nil
        guard let event = state.pending else { states[bookID] = state; return }
        state.pending = nil
        state.lastPublished = event
        state.lastPublishedAt = clock.now
        states[bookID] = state
        publish(event)
    }

    /// Drops any scheduled stale update and always publishes the cancellation.
    public func cancel(bookID: UUID) {
        states[bookID]?.flushTask?.cancel()
        states[bookID] = nil
        publishCancelled(bookID)
    }
}
