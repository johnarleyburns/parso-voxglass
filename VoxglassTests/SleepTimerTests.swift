import Testing
import Foundation
@testable import VoxglassCore

/// Pure sleep-timer arithmetic (P0-2) with an injected clock — no `Task.sleep`.
@MainActor
@Suite struct SleepTimerTests {

    /// Mutable injectable clock.
    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current.addTimeInterval(seconds) }
    }

    @Test func remainingCountsDownFromInjectedClock() {
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        timer.arm(.duration(TimeInterval(30 * 60)))

        #expect(timer.remaining == TimeInterval(30 * 60))
        clock.advance(TimeInterval(10 * 60))
        #expect(timer.remaining == TimeInterval(20 * 60))
        clock.advance(TimeInterval(25 * 60))
        #expect(timer.remaining == 0)  // Never negative
    }

    @Test func firesExactlyOnceAtDeadline() {
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        var fireCount = 0
        timer.onFire = { fireCount += 1 }
        timer.arm(.duration(TimeInterval(60)))

        timer.tick()
        #expect(fireCount == 0)  // Before deadline: no fire

        clock.advance(TimeInterval(61))
        timer.tick()
        timer.tick()   // idempotent
        timer.tick()
        #expect(fireCount == 1)  // Fires exactly once even across repeated ticks
        #expect(timer.mode == .off)  // Mode resets to off after firing
    }

    @Test func pauseDoesNotSkewDeadline() {
        // The timer is wall-clock: only the injected clock advances it.
        let clock = Clock()
        let timer = SleepTimer(now: clock.now)
        timer.arm(.duration(TimeInterval(300)))
        clock.advance(TimeInterval(100))   // "playback paused" for 100s of wall time
        #expect(timer.remaining == 200)
    }

    @Test func endOfChapterHasNoRemaining() {
        let timer = SleepTimer()
        timer.arm(.endOfChapter)
        #expect(timer.remaining == nil)
        #expect(timer.isArmed)
    }

    @Test func cancelDisarms() {
        let timer = SleepTimer()
        timer.arm(.duration(TimeInterval(60)))
        timer.cancel()
        #expect(timer.mode == .off)
        #expect(timer.remaining == nil)
        #expect(!(timer.isArmed))
    }

    @Test func endOfChapterNeverFiresViaTick() {
        let timer = SleepTimer()
        var fired = false
        timer.onFire = { fired = true }
        timer.arm(.endOfChapter)
        timer.tick()
        #expect(!(fired))  // End-of-chapter is fired by the coordinator, not the tick
    }
}
