import Testing
import Foundation
@testable import VoxglassCore

/// Tests the pure `PlaybackCoordinator.nowPlayingInfo(...)` builder (Step 0b). It
/// now returns a plain `NowPlayingInfo` value (no MediaPlayer), so the payload is
/// fully assertable on the host; the device test only has to verify iOS renders
/// it. Artwork is handled separately by the platform bridge and is covered by
/// `NowPlayingArtworkTests`.
@Suite struct NowPlayingInfoTests {

    private func makeSession() -> PlaybackSession {
        let bookID = UUID()
        let chapter = Chapter(bookID: bookID, title: "Chapter One", index: 0, duration: 300)
        let book = Book(title: "Moby Dick", authors: ["Herman Melville"], sourceID: UUID())
        return PlaybackSession(
            book: book,
            chapters: [chapter],
            chapter: chapter,
            position: 42,
            duration: 300,
            isPlaying: true
        )
    }

    @Test func setsCoreMetadata() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.0, isPlaying: true
        )
        #expect(info.title == "Chapter One")
        #expect(info.albumTitle == "Moby Dick")
        #expect(info.artist == "Herman Melville")
        #expect(info.elapsed == 42)
        #expect(info.duration == 300)
    }

    @Test func setsBothRateKeysWhenPlaying() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: true
        )
        #expect(info.reportedRate == 1.5)
        #expect(info.defaultRate == 1.5)
    }

    @Test func playbackRateIsZeroWhenPausedButDefaultRatePreserved() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: false
        )
        #expect(info.reportedRate == 0.0)  // Paused rate must be 0 so the lock-screen scrubber stops advancing
        #expect(info.defaultRate == 1.5)
    }

    @Test func durationOmittedWhenNil() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 0, duration: nil,
            rate: 1.0, isPlaying: true
        )
        #expect(info.duration == nil)
    }
}
