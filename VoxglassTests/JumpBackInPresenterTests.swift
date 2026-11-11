import Foundation
import Testing
@testable import VoxglassCore

@Suite struct JumpBackInPresenterTests {
    private func book(_ title: String) -> BookWithChapters {
        let b = Book(title: title, authors: ["A"], sourceID: UUID())
        return BookWithChapters(book: b, chapters: [Chapter(bookID: b.id, title: "One", index: 0, duration: 300)])
    }

    private func ids(_ books: [BookWithChapters]) -> [UUID] { books.map(\.book.id) }

    @Test func staleSnapshotKeepsPausedBook() {
        let a = book("A"), b = book("B"), c = book("C")
        let out = JumpBackInPresenter.books(recentlyPlayed: [a, b, c], heroBookID: b.book.id)
        #expect(ids(out) == [a.book.id, c.book.id])
    }

    @Test func heroAtPositionZero() {
        let a = book("A"), b = book("B"), c = book("C")
        #expect(ids(JumpBackInPresenter.books(recentlyPlayed: [a, b, c], heroBookID: a.book.id)) == [b.book.id, c.book.id])
    }

    @Test func heroAnywhereKeepsOrder() {
        let a = book("A"), b = book("B"), c = book("C"), d = book("D")
        let out = JumpBackInPresenter.books(recentlyPlayed: [a, b, c, d], heroBookID: c.book.id)
        #expect(ids(out) == [a.book.id, b.book.id, d.book.id])
    }

    @Test func nilHeroReturnsUnchanged() {
        let a = book("A"), b = book("B")
        #expect(JumpBackInPresenter.books(recentlyPlayed: [a, b], heroBookID: nil) == [a, b])
    }

    @Test func absentHeroReturnsUnchanged() {
        let a = book("A"), b = book("B")
        #expect(JumpBackInPresenter.books(recentlyPlayed: [a, b], heroBookID: UUID()) == [a, b])
    }

    @Test func singleHeroBookIsEmpty() {
        let a = book("A")
        #expect(JumpBackInPresenter.books(recentlyPlayed: [a], heroBookID: a.book.id).isEmpty)
    }

    @Test func twoBooksOneHeroLeavesOne() {
        let a = book("A"), b = book("B")
        let out = JumpBackInPresenter.books(recentlyPlayed: [a, b], heroBookID: a.book.id)
        #expect(ids(out) == [b.book.id])
    }

    @Test func listenViewUsesPresenterNotDropFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let listen = try String(contentsOf: root.appendingPathComponent("Voxglass/Features/Listen/ListenView.swift"), encoding: .utf8)
        #expect(listen.contains("JumpBackInPresenter.books("))
        #expect(!listen.contains("recentlyPlayed.dropFirst()"))
    }

    @Test func sessionBookIDNonNilForEveryKindExceptNone() {
        let b = Book(title: "M", authors: ["A"], sourceID: UUID())
        let ch = Chapter(bookID: b.id, title: "One", index: 0, duration: 300)
        let s = PlaybackSession(book: b, chapters: [ch], chapter: ch, position: 1, duration: 300, isPlaying: true)
        let phases: [PlaybackPhase] = [.idle, .preparing, .playing, .paused]
        for phase in phases {
            let p = ListenHeroPresentation(session: s, phase: phase, recentBookID: nil)
            if p.kind == .none {
                #expect(p.sessionBookID == nil)
            } else {
                #expect(p.sessionBookID == b.id)
            }
        }
    }
}
