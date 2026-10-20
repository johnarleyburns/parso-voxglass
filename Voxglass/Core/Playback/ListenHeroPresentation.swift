import Foundation

/// What the Listen tab's top hero should say, derived from the live playback
/// session rather than persisted progress or recent-history ordering.
public struct ListenHeroPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No live session: fall back to the recent-history Continue/Play card.
        case none
        /// The live session is audibly playing.
        case playing
        /// The live session is stopped but resumable.
        case paused
        /// The live session is loading; neither Resume nor Playing is true.
        case preparing
        /// The live session failed and is recovering or needs attention.
        case recovery
    }

    public let kind: Kind
    /// The live session's book; `nil` only when `kind == .none`.
    public let sessionBookID: UUID?
    /// True when the live session is a different book than the recent-history one.
    public let replacesRecentBook: Bool

    public init(session: PlaybackSession?, phase: PlaybackPhase, recentBookID: UUID?) {
        guard let session else {
            self.kind = .none
            self.sessionBookID = nil
            self.replacesRecentBook = false
            return
        }
        switch phase {
        case .idle:
            kind = .none
        case .preparing:
            kind = .preparing
        case .failed:
            kind = .recovery
        case .playing:
            kind = session.isPlaying ? .playing : .paused
        case .paused:
            kind = .paused
        }
        if kind == .none {
            sessionBookID = nil
            replacesRecentBook = false
        } else {
            sessionBookID = session.book.id
            replacesRecentBook = recentBookID != nil && recentBookID != session.book.id
        }
    }

    /// Whether the hero is the Now Playing card (as opposed to Continue Listening).
    public var showsNowPlaying: Bool {
        switch kind {
        case .playing, .preparing, .recovery: true
        case .none, .paused: false
        }
    }
}
