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

    public init(message: String, isRetryable: Bool) {
        self.message = message
        self.isRetryable = isRetryable
    }
}
