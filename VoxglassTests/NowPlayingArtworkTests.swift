import XCTest
@testable import Voxglass

/// Lock-screen artwork caching (P0-4): fetched once per book, never per tick, and
/// a fallback covers books with no art. Asserted against a counting fake provider
/// (returning raw `Data`) and a `NoopPlaybackBridge`, so no network / MediaPlayer.
@MainActor
final class NowPlayingArtworkTests: XCTestCase {

    /// MainActor call counter (both the test and the provider run on MainActor).
    private final class FetchCounter { var count = 0 }
    /// Stand-in cover bytes; the coordinator only forwards them to the bridge.
    private let coverData = Data([0x01, 0x02, 0x03])

    private func makeBook(title: String, cover: Bool) -> BookWithChapters {
        let bookID = UUID()
        let chapter = Chapter(
            bookID: bookID, title: "Ch 0", index: 0, duration: 100,
            localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString).mp3")
        )
        let book = Book(
            title: title, authors: ["A"], sourceID: UUID(),
            coverURL: cover ? URL(string: "https://archive.org/services/img/\(bookID.uuidString)") : nil
        )
        return BookWithChapters(book: book, chapters: [chapter])
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testArtworkFetchedOncePerBookNotPerTick() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-once-\(UUID().uuidString)")
        let coordinator = PlaybackCoordinator(engine: FakeAudioEngine(), positionStore: SQLitePositionStore(database: db))
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "A", cover: true))
        await waitUntil { counter.count >= 1 }

        // Simulate 10 "ticks" — each re-emits Now Playing but must not re-fetch.
        for _ in 0..<10 { coordinator.setPlaybackRate(1.0) }

        XCTAssertEqual(counter.count, 1, "Cover art is fetched once per book, not per tick")
    }

    func testFallbackUsedWhenCoverURLIsNil() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-fallback-\(UUID().uuidString)")
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: FakeAudioEngine(),
            positionStore: SQLitePositionStore(database: db),
            bridge: bridge
        )
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "No Cover", cover: false))

        XCTAssertEqual(bridge.lastArtworkData, .some(nil),
                       "A coverless book still requests fallback artwork (setArtwork(nil))")
        XCTAssertEqual(counter.count, 0, "No fetch is attempted when there is no cover URL")
    }

    func testArtworkRefreshesOnBookChange() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-change-\(UUID().uuidString)")
        let coordinator = PlaybackCoordinator(engine: FakeAudioEngine(), positionStore: SQLitePositionStore(database: db))
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "A", cover: true))
        await waitUntil { counter.count >= 1 }
        await coordinator.play(makeBook(title: "B", cover: true))
        await waitUntil { counter.count >= 2 }

        XCTAssertEqual(counter.count, 2, "A different book triggers exactly one more fetch")
    }
}
