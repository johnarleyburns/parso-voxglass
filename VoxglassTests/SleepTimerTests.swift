import XCTest
@testable import Voxglass

/// Pure sleep-timer arithmetic (P0-2) with an injected clock — no `Task.sleep`.
@MainActor
final class SleepTimerTests: XCTestCase {

    /// Mutable injectable clock.
    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current.addTimeInterval(seconds) }
    }

    func testRemainingCountsDownFromInjectedClock() {
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        timer.arm(.duration(30 * 60))

        XCTAssertEqual(timer.remaining, 30 * 60)
        clock.advance(10 * 60)
        XCTAssertEqual(timer.remaining, 20 * 60)
        clock.advance(25 * 60)
        XCTAssertEqual(timer.remaining, 0, "Never negative")
    }

    func testFiresExactlyOnceAtDeadline() {
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        var fireCount = 0
        timer.onFire = { fireCount += 1 }
        timer.arm(.duration(60))

        timer.tick()
        XCTAssertEqual(fireCount, 0, "Before deadline: no fire")

        clock.advance(61)
        timer.tick()
        timer.tick()   // idempotent
        timer.tick()
        XCTAssertEqual(fireCount, 1, "Fires exactly once even across repeated ticks")
        XCTAssertEqual(timer.mode, .off, "Mode resets to off after firing")
    }

    func testPauseDoesNotSkewDeadline() {
        // The timer is wall-clock: only the injected clock advances it.
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        timer.arm(.duration(300))
        clock.advance(100)   // "playback paused" for 100s of wall time
        XCTAssertEqual(timer.remaining, 200)
    }

    func testEndOfChapterHasNoRemaining() {
        let timer = SleepTimer()
        timer.arm(.endOfChapter)
        XCTAssertNil(timer.remaining)
        XCTAssertTrue(timer.isArmed)
    }

    func testCancelDisarms() {
        let timer = SleepTimer()
        timer.arm(.duration(60))
        timer.cancel()
        XCTAssertEqual(timer.mode, .off)
        XCTAssertNil(timer.remaining)
        XCTAssertFalse(timer.isArmed)
    }

    func testEndOfChapterNeverFiresViaTick() {
        let timer = SleepTimer()
        var fired = false
        timer.onFire = { fired = true }
        timer.arm(.endOfChapter)
        timer.tick()
        XCTAssertFalse(fired, "End-of-chapter is fired by the coordinator, not the tick")
    }
}
