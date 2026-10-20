import Foundation

public enum PlaybackPhase: Equatable, Sendable {
    case idle
    case preparing
    case paused
    case playing
    case failed(PlaybackFailure)
}

public struct PlaybackFailure: Equatable, Sendable {
    public let message: String
    public let isRetryable: Bool
    /// True when the imported local file can be recovered by reselecting its
    /// folder or file in the Files picker.
    public let needsReselect: Bool

    /// True when a local import has no reachable file binding at all and the
    /// user must run Reconnect Audio for this book.
    public let needsReconnect: Bool

    public init(message: String, isRetryable: Bool, needsReselect: Bool = false, needsReconnect: Bool = false) {
        self.needsReconnect = needsReconnect
        self.message = message
        self.isRetryable = isRetryable
        self.needsReselect = needsReselect
    }
}
