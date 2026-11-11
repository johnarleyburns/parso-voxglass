import Foundation

/// Pure handoff state between "user asked to resume and open the player" and
/// "the coordinator published a renderable session for that book".
public struct NowPlayingPresentationState: Equatable, Sendable {
    public private(set) var isNowPlayingPresented = false
    public private(set) var pendingBookID: UUID?

    public init() {}

    /// A newer request supersedes any older pending one. Ignored when the
    /// sheet is already up (the caller just selects the book).
    public mutating func requestPresentation(for bookID: UUID) {
        guard !isNowPlayingPresented else { pendingBookID = nil; return }
        pendingBookID = bookID
    }

    /// Presents once, only for the pending book's published session.
    @discardableResult
    public mutating func consumeReadySession(bookID: UUID?) -> Bool {
        guard let pending = pendingBookID, let bookID, pending == bookID else { return false }
        pendingBookID = nil
        isNowPlayingPresented = true
        return true
    }

    /// Selection cancelled, failed, torn down, or the user navigated away.
    public mutating func cancelPending() { pendingBookID = nil }

    public mutating func setPresented(_ presented: Bool) {
        isNowPlayingPresented = presented
        if !presented { pendingBookID = nil }
    }
}

/// Keeps the visible Listen hero mounted between a Resume tap and the sheet
/// actually covering it, so the card never swaps to a different-height layout.
public struct ListenHeroHandoffState: Equatable, Sendable {
    public private(set) var isHandingOff = false
    public init() {}
    public var allowsLiveHeroReplacement: Bool { !isHandingOff }
    public mutating func didTapResume() { isHandingOff = true }
    public mutating func didPresentNowPlayingSheet() { isHandingOff = false }
    public mutating func didCancel() { isHandingOff = false }
}
