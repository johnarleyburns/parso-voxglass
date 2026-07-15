import XCTest
@testable import VoxglassCore

@MainActor
final class PlaybackCoordinatorSilenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        super.tearDown()
    }

    private func makeBook() -> BookWithChapters {
        let bookID = UUID()
        let ch = Chapter(
            bookID: bookID, title: "Ch 0", index: 0, duration: 100,
            localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-0.mp3")
        )
        return BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: [ch])
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine) {
        let db = AppDatabase.makeTemporaryDatabase(named: "silence-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))
        return (coordinator, engine)
    }

    func testSilenceDetectedBoostsRate() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(1.0)
        engine.reset()

        engine.fireSilenceChanged(true)

        XCTAssertTrue(engine.calls.contains(.setRate(1.5)), "At 1.0×, silence should boost to 1.5× (relative)")
    }

    func testSpeechRestoresUserRate() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(1.5)
        engine.reset()

        engine.fireSilenceChanged(true)
        XCTAssertTrue(engine.calls.contains(.setRate(2.25)), "At 1.5×, silence should boost to 2.25×")

        engine.reset()
        engine.fireSilenceChanged(false)
        XCTAssertTrue(engine.calls.contains(.setRate(1.5)), "Speech should restore user rate 1.5×")
    }

    func testPauseResetsBoost() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)
        XCTAssertTrue(engine.calls.contains(.setRate(1.5)), "At 1.0×, silence should boost to 1.5×")

        coordinator.pause()
        engine.reset()

        engine.fireSilenceChanged(true)
        XCTAssertTrue(engine.calls.contains(.setRate(1.5)), "After pause, next silence should still trigger a fresh boost")
    }

    func testManualRateChangeResetsBoost() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)
        XCTAssertTrue(engine.calls.contains(.setRate(1.5)))

        engine.reset()
        coordinator.setPlaybackRate(2.0)

        engine.fireSilenceChanged(true)
        XCTAssertTrue(engine.calls.contains(.setRate(3.0)), "At 2.0×, silence should boost to 3.0× (relative)")
    }

    func testSkipSilenceDisabledDoesNotBoost() async {
        UserDefaults.standard.set(false, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)

        let rateCalls = engine.calls.filter {
            if case .setRate = $0 { return true }
            return false
        }
        XCTAssertTrue(rateCalls.isEmpty, "When skip silence is disabled, no rate change should occur")
    }

    func testMaxRateDoesNotDropOnSilence() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(3.5)
        engine.reset()

        engine.fireSilenceChanged(true)

        XCTAssertTrue(engine.calls.contains(.setRate(3.5)), "At 3.5×, silence boost must not drop the rate")
    }

    func testHighRateClampedToMax() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(2.5)
        engine.reset()

        engine.fireSilenceChanged(true)

        XCTAssertTrue(engine.calls.contains(.setRate(3.5)), "At 2.5×, 1.5× boost would be 3.75×, must clamp to 3.5×")
    }
}
