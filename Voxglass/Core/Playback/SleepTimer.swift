import Foundation

/// Sleep timer (P0-2). A deadline-based, wall-clock timer with an injected clock
/// so it is fully unit-testable with no `Task.sleep`. The coordinator drives it
/// from its own 0.5s task and reacts to `onFire`. End-of-chapter is armed here but
/// fired by the coordinator (it must cancel gapless preload so the queue cannot
/// physically advance past the current chapter).
@MainActor
public final class SleepTimer: ObservableObject {
    public enum Mode: Equatable {
        case off
        case duration(TimeInterval)
        case endOfChapter
    }

    @Published public private(set) var mode: Mode = .off

    private let now: () -> Date
    private var deadline: Date?
    private var hasFired = false

    /// Called exactly once when a `.duration` deadline passes.
    public var onFire: (() -> Void)?

    public nonisolated init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var isArmed: Bool { mode != .off }

    /// Remaining time for a `.duration` timer; `nil` for `.off`/`.endOfChapter`.
    /// Computed from the injected clock against a fixed deadline, so pause,
    /// background, and rate changes never skew it.
    public var remaining: TimeInterval? {
        guard case .duration = mode, let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now()))
    }

    public func arm(_ newMode: Mode) {
        mode = newMode
        hasFired = false
        switch newMode {
        case .off, .endOfChapter:
            deadline = nil
        case .duration(let seconds):
            deadline = now().addingTimeInterval(seconds)
        }
    }

    public func cancel() {
        arm(.off)
    }

    /// Deadline check; fires `onFire` exactly once. Idempotent across repeated
    /// ticks after the deadline.
    public func tick() {
        guard case .duration = mode, let deadline, !hasFired else { return }
        if now() >= deadline {
            hasFired = true
            mode = .off
            self.deadline = nil
            onFire?()
        }
    }
}
