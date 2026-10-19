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

    public init(message: String, isRetryable: Bool, needsReselect: Bool = false) {
        self.message = message
        self.isRetryable = isRetryable
        self.needsReselect = needsReselect
    }
}
