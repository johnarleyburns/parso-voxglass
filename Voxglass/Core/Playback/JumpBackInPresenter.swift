import Foundation

/// What "Jump Back In" should show: every recently-played book except the one
/// the hero/Continue-Listening slot is already showing, identified by book ID
/// (never by position in `recentlyPlayed`, which can lag the live session).
public enum JumpBackInPresenter {
    public static func books(
        recentlyPlayed: [BookWithChapters],
        heroBookID: UUID?
    ) -> [BookWithChapters] {
        guard let heroBookID else { return recentlyPlayed }
        return recentlyPlayed.filter { $0.book.id != heroBookID }
    }
}
