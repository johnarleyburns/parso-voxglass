import MediaPlayer
import XCTest
@testable import Voxglass

/// Tests the pure `PlaybackCoordinator.nowPlayingInfo(...)` builder (Step 0b). The
/// dictionary is fully assertable here, so the device test (D-2) only has to
/// verify iOS renders it — not that it is correct.
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
            rate: 1.0, isPlaying: true, artwork: nil
        )
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Chapter One")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Moby Dick")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Herman Melville")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
    }

    func testSetsBothRateKeysWhenPlaying() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: true, artwork: nil
        )
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
    }

    func testPlaybackRateIsZeroWhenPausedButDefaultRatePreserved() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 42, duration: 300,
            rate: 1.5, isPlaying: false, artwork: nil
        )
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0,
                       "Paused rate must be 0 so the lock-screen scrubber stops advancing")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
    }

    func testArtworkKeyOmittedWhenNil() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 0, duration: 300,
            rate: 1.0, isPlaying: true, artwork: nil
        )
        XCTAssertNil(info[MPMediaItemPropertyArtwork])
    }

    func testArtworkKeySetWhenPresent() {
        let image = UIImage(systemName: "book.fill")!
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 0, duration: 300,
            rate: 1.0, isPlaying: true, artwork: artwork
        )
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    }

    func testDurationOmittedWhenNil() {
        let info = PlaybackCoordinator.nowPlayingInfo(
            session: makeSession(), currentTime: 0, duration: nil,
            rate: 1.0, isPlaying: true, artwork: nil
        )
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }
}
