import XCTest
@testable import Voxglass

/// The hard sleep-timer interactions through the coordinator (P0-2), asserted on
/// the FakeAudioEngine call log. No AVFoundation.
@MainActor
final class PlaybackCoordinatorSleepTests: XCTestCase {

    private func makeBook(chapters: Int = 3) -> BookWithChapters {
        let bookID = UUID()
        let chs = (0..<chapters).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        return BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chs)
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine) {
        let db = AppDatabase.makeTemporaryDatabase(named: "sleep-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))
        coordinator.fadeOutDuration = 0.005
        return (coordinator, engine)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testEndOfChapterCancelsPreloadThenDoesNotRollIntoNextChapter() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        coordinator.setSleepTimer(.endOfChapter)
        XCTAssertTrue(engine.didCancelPreload, "Arming end-of-chapter cancels the gapless preload")

        engine.reset()
        engine.firePlaybackEnded()      // chapter ends
        await waitUntil { engine.calls.contains(.pause) }

        XCTAssertTrue(engine.calls.contains(.pause), "Playback pauses at chapter end")
        XCTAssertTrue(engine.loadCalls.isEmpty, "It must NOT load the next chapter")
    }

    func testCancellingEndOfChapterReArmsPreload() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setSleepTimer(.endOfChapter)
        engine.reset()

        coordinator.setSleepTimer(.off)

        let preloaded = engine.calls.contains { if case .preloadNext = $0 { return true } else { return false } }
        XCTAssertTrue(preloaded, "Cancelling end-of-chapter re-arms the gapless preload")
    }

    func testFadeOutRampsVolumeDownAndRestoresToOne() async {
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        await coordinator.fadeOutAndPause()

        let volumes: [Float] = engine.calls.compactMap {
            if case let .setVolume(v) = $0 { return v } else { return nil }
        }
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertEqual(volumes.last, 1.0, "Volume must be restored to 1.0 or the next play is silent")
        // A pause occurs before the final restore.
        let pauseIndex = engine.calls.firstIndex(of: .pause)
        let restoreIndex = engine.calls.lastIndex(of: .setVolume(1.0))
        XCTAssertNotNil(pauseIndex)
        XCTAssertNotNil(restoreIndex)
        XCTAssertLessThan(pauseIndex ?? .max, restoreIndex ?? .min)
        // The ramp reaches (near) zero before the restore.
        XCTAssertTrue(volumes.contains(0.0), "The ramp reaches zero before pausing")
    }

    func testDurationTimerFireFadesAndPauses() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "sleep-fire-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        var current = Date(timeIntervalSince1970: 5_000)
        let timer = SleepTimer(now: { current })
        let coordinator = PlaybackCoordinator(
            engine: engine, positionStore: SQLitePositionStore(database: db), sleepTimer: timer
        )
        coordinator.fadeOutDuration = 0.005

        await coordinator.play(makeBook())
        coordinator.setSleepTimer(.duration(60))
        engine.reset()

        current.addTimeInterval(61)
        timer.tick()   // deadline passed → onFire → fade + pause

        await waitUntil { engine.calls.last == .setVolume(1.0) }
        XCTAssertTrue(engine.calls.contains(.pause))
        XCTAssertEqual(engine.calls.last, .setVolume(1.0))
    }

    func testSleepTimerIsFree() async {
        EntitlementCache.shared.setTestEntitlement(false)
        defer { EntitlementCache.shared.setTestEntitlement(nil) }
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()
        coordinator.setSleepTimer(.endOfChapter)
        XCTAssertTrue(engine.didCancelPreload, "Sleep timer must work with no Pro entitlement")
    }
}
