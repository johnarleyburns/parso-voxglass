import Foundation

/// Per-rung circuit breaker (§2.1.2): after `consecutiveFailures >= threshold`
/// consecutive failures the rung is skipped until `openUntil`.
public struct CircuitBreaker: Sendable, Equatable {
    public var consecutiveFailures: Int
    public var openUntil: Date?

    public init(consecutiveFailures: Int = 0, openUntil: Date? = nil) {
        self.consecutiveFailures = consecutiveFailures
        self.openUntil = openUntil
    }

    public var isOpen: Bool {
        openUntil != nil
    }

    /// True if the breaker has tripped and the rung must be skipped now.
    public func shouldSkip(now: Date) -> Bool {
        guard let openUntil else { return false }
        return now < openUntil
    }

    public mutating func recordFailure(now: Date) {
        consecutiveFailures += 1
        if consecutiveFailures >= NeedsDiscoveryConstants.breakerFailureThreshold {
            openUntil = now.addingTimeInterval(NeedsDiscoveryConstants.breakerCooldown)
        }
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }
}
