import XCTest
@testable import Voxglass

/// Rate behaviour through the coordinator, asserted on the FakeAudioEngine call
/// log (P0-1). No AVFoundation, no simulator audio.
@MainActor
final class PlaybackCoordinatorRateTests: XCTestCase {

    private func makeBook(title: String, chapters: Int = 2) -> BookWithChapters {
        let bookID = UUID()
        let chs = (0..<chapters).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        let book = Book(id: bookID, title: title, authors: ["A"], sourceID: UUID())
        return BookWithChapters(book: book, chapters: chs)
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine) {
        let db = AppDatabase.makeTemporaryDatabase(named: "coord-rate-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let rateStore = PlaybackRateStore(defaults: UserDefaults(suiteName: "cr-\(UUID().uuidString)")!)
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: SQLitePositionStore(database: db),
            rateStore: rateStore
        )
        return (coordinator, engine)
    }

    /// Polls the MainActor call log until `predicate` holds or the budget expires,
    /// letting the fire-and-forget `onItemChanged` Task complete.
    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRateIsRememberedPerBook() async {
        let (coordinator, engine) = makeCoordinator()
        let bookA = makeBook(title: "A")
        let bookB = makeBook(title: "B")

        await coordinator.play(bookA)
        XCTAssertEqual(engine.rate, 1.0)

        coordinator.setPlaybackRate(1.5)
        XCTAssertEqual(engine.rate, 1.5)

        engine.reset()
        await coordinator.play(bookB)
        XCTAssertEqual(engine.rate, 1.0, "Book B has no stored rate → default 1.0×")
        XCTAssertTrue(engine.rateCalls.contains(1.0))

        engine.reset()
        await coordinator.play(bookA)
        XCTAssertEqual(engine.rate, 1.5, "Reopening A restores 1.5×")
        XCTAssertTrue(engine.rateCalls.contains(1.5))
    }

    func testRateIsReAssertedOnGaplessAdvance() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook(title: "A", chapters: 3))
        coordinator.setPlaybackRate(2.0)
        engine.reset()

        engine.fireItemChanged()   // simulate AVQueuePlayer gapless advance
        await waitUntil { engine.rateCalls.contains(2.0) }

        XCTAssertTrue(engine.rateCalls.contains(2.0), "Rate re-asserted after item change")
    }

    func testSetPlaybackRateClampsAndPublishes() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook(title: "A"))
        coordinator.setPlaybackRate(99)
        XCTAssertEqual(engine.rate, 3.5)
        XCTAssertEqual(coordinator.playbackRate, 3.5)
    }

    func testRateAppliedAfterLoadBeforePlay() async {
        let (coordinator, engine) = makeCoordinator()
        let book = makeBook(title: "A")
        // Pre-seed a stored rate by playing + setting, then replay.
        await coordinator.play(book)
        coordinator.setPlaybackRate(1.25)
        engine.reset()
        await coordinator.play(book)
        // setRate must appear before play in the log.
        let rateIndex = engine.calls.firstIndex { if case .setRate = $0 { return true } else { return false } }
        let playIndex = engine.calls.firstIndex(of: .play)
        XCTAssertNotNil(rateIndex)
        XCTAssertNotNil(playIndex)
        XCTAssertLessThan(rateIndex ?? .max, playIndex ?? .min)
    }
}
