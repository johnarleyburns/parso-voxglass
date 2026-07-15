import XCTest
@testable import Voxglass

/// Tests the pure `PlaybackCoordinator.nowPlayingInfo(...)` builder (Step 0b). It
/// now returns a plain `NowPlayingInfo` value (no MediaPlayer), so the payload is
/// fully assertable on the host; the device test only has to verify iOS renders
/// it. Artwork is handled separately by the platform bridge and is covered by
/// `NowPlayingArtworkTests`.
final class NowPlayingInfoTests: XCTestCase {

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

    func testSetsCoreMetadata() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.0, isPlaying: true
        )
        XCTAssertEqual(info.title, "Chapter One")
        XCTAssertEqual(info.albumTitle, "Moby Dick")
        XCTAssertEqual(info.artist, "Herman Melville")
        XCTAssertEqual(info.elapsed, 42)
        XCTAssertEqual(info.duration, 300)
    }

    func testSetsBothRateKeysWhenPlaying() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: true
        )
        XCTAssertEqual(info.reportedRate, 1.5)
        XCTAssertEqual(info.defaultRate, 1.5)
    }

    func testPlaybackRateIsZeroWhenPausedButDefaultRatePreserved() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: false
        )
        XCTAssertEqual(info.reportedRate, 0.0,
                       "Paused rate must be 0 so the lock-screen scrubber stops advancing")
        XCTAssertEqual(info.defaultRate, 1.5)
    }

    func testDurationOmittedWhenNil() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 0, duration: nil,
            rate: 1.0, isPlaying: true
        )
        XCTAssertNil(info.duration)
    }
}
