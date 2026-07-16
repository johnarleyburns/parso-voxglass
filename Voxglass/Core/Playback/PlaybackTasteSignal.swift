import Foundation

/// A taste-capture event emitted by `PlaybackCoordinator` after a playback
/// position has been persisted. Carries enough context for the recommendation
/// layer to compute a completion-calibrated profile increment without
/// re-reading playback state.
public struct PlaybackTasteSignal: Equatable, Sendable {
    public let bookID: UUID
    public let isFavorite: Bool
    public let position: TimeInterval
    public let duration: TimeInterval?
    public let isFinished: Bool

    public init(
        bookID: UUID,
        isFavorite: Bool,
        position: TimeInterval,
        duration: TimeInterval?,
        isFinished: Bool
    ) {
        self.bookID = bookID
        self.isFavorite = isFavorite
        self.position = position
        self.duration = duration
        self.isFinished = isFinished
    }
}
