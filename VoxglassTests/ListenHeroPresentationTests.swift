import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ListenHeroPresentationTests {
    private func session(title: String = "Moby Dick", playing: Bool) -> PlaybackSession {
        let book = Book(title: title, authors: ["A"], sourceID: UUID())
        let chapter = Chapter(bookID: book.id, title: "One", index: 0, duration: 300)
        return PlaybackSession(book: book, chapters: [chapter], chapter: chapter, position: 10, duration: 300, isPlaying: playing)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func noSessionIsNoneRegardlessOfRecent() {
        let p = ListenHeroPresentation(session: nil, phase: .idle, recentBookID: UUID())
        #expect(p.kind == .none && p.sessionBookID == nil && !p.showsNowPlaying && !p.replacesRecentBook)
        #expect(ListenHeroPresentation(session: nil, phase: .idle, recentBookID: nil).kind == .none)
    }

    @Test func playingSession() {
        let s = session(playing: true)
        let p = ListenHeroPresentation(session: s, phase: .playing, recentBookID: s.book.id)
        #expect(p.kind == .playing && p.showsNowPlaying && p.sessionBookID == s.book.id && !p.replacesRecentBook)
    }

    @Test func pausedSessionIsContinueListening() {
        let s = session(playing: false)
        let p = ListenHeroPresentation(session: s, phase: .paused, recentBookID: s.book.id)
        #expect(p.kind == .paused && !p.showsNowPlaying)
        // Engine says playing but session flag disagrees: never claim Playing.
        #expect(ListenHeroPresentation(session: s, phase: .playing, recentBookID: nil).kind == .paused)
    }

    @Test func preparingAndRecoveryNeverClaimPlaying() {
        let s = session(playing: true)
        let prep = ListenHeroPresentation(session: s, phase: .preparing, recentBookID: nil)
        #expect(prep.kind == .preparing && prep.showsNowPlaying)
        let failure = PlaybackFailure(message: "x", isRetryable: true)
        let rec = ListenHeroPresentation(session: s, phase: .failed(failure), recentBookID: nil)
        #expect(rec.kind == .recovery && rec.showsNowPlaying)
    }

    @Test func terminalIdleSessionFallsBackToRecent() {
        let s = session(playing: false)
        let p = ListenHeroPresentation(session: s, phase: .idle, recentBookID: s.book.id)
        #expect(p.kind == .none && p.sessionBookID == nil)
    }

    @Test func activeSessionDiffersFromRecentAndReplacement() {
        let recent = session(title: "Old", playing: false)
        let live = session(title: "New", playing: true)
        let p = ListenHeroPresentation(session: live, phase: .playing, recentBookID: recent.book.id)
        #expect(p.kind == .playing && p.sessionBookID == live.book.id && p.replacesRecentBook)
        let next = session(title: "Newer", playing: true)
        let q = ListenHeroPresentation(session: next, phase: .playing, recentBookID: recent.book.id)
        #expect(q.sessionBookID == next.book.id && q.sessionBookID != p.sessionBookID)
    }

    @Test func listenViewUsesLiveSessionAndSeparateControls() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        #expect(listen.contains("ListenHeroPresentation("))
        #expect(listen.contains("playback.currentSession"))
        #expect(listen.contains("playback.togglePlayPause()"))
        #expect(listen.contains("frame(width: 44, height: 44)"))
        #expect(listen.contains("accessibilityReduceMotion"))
        #expect(listen.contains("accessibilityHidden(true)"))
        #expect(listen.contains("listen.nowPlaying.pause"))
    }
}
