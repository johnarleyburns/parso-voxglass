import Foundation
import Testing
@testable import VoxglassWatchCore
@testable import VoxglassWatchProtocol

@Suite("Watch listening (redesign §5–§6)")
struct WatchListeningTests {
    @Test("Skips clamp to the chapter")
    func skipClamps() {
        #expect(WatchSkip.position(from: 10, by: -WatchSkip.backward, duration: 100) == 0)
        #expect(WatchSkip.position(from: 50, by: WatchSkip.forward, duration: 100) == 80)
        #expect(WatchSkip.position(from: 90, by: WatchSkip.forward, duration: 100) == 100)
    }

    @Test("Speed snaps to 0.05 within 0.5–3 and labels without trailing zeros")
    func speedNormalizesAndLabels() {
        #expect(WatchSpeed.normalized(1.2349) == 1.25)
        #expect(WatchSpeed.normalized(0.1) == 0.5)
        #expect(WatchSpeed.normalized(9) == 3)
        #expect(WatchSpeed.normalized(.nan) == 1)
        #expect(WatchSpeed.label(1) == "1×")
        #expect(WatchSpeed.label(1.2) == "1.2×")
        #expect(WatchSpeed.label(1.25) == "1.25×")
        #expect(WatchSpeed.isDetent(1.5))
        #expect(!WatchSpeed.isDetent(1.35))
    }

    @Test("Speed is remembered per book")
    func speedStorePersists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speeds-\(UUID().uuidString).json")
        let store = WatchSpeedStore(url: url)
        try await store.setRate(1.37, for: WatchBookID("a"))
        #expect(await store.rate(for: WatchBookID("a")) == 1.35)
        #expect(await store.rate(for: WatchBookID("b")) == 1)
        let reopened = WatchSpeedStore(url: url)
        #expect(await reopened.rate(for: WatchBookID("a")) == 1.35)
    }

    @Test("Sleep timer: minutes count down; end of chapter uses wall-clock time at the speed")
    func sleepRemaining() {
        let start = Date(timeIntervalSince1970: 1_000)
        let minutes = WatchSleepTimer(mode: .minutes(15), armedAt: start)
        #expect(minutes.remaining(at: start.addingTimeInterval(60), chapterRemaining: 0, rate: 1) == 14 * 60)
        #expect(minutes.remaining(at: start.addingTimeInterval(16 * 60), chapterRemaining: 0, rate: 1) == 0)
        let chapter = WatchSleepTimer(mode: .endOfChapter, armedAt: start)
        #expect(chapter.remaining(at: start, chapterRemaining: 300, rate: 1.5) == 200)
    }

    @Test("Sleep fade only in the last ten seconds")
    func sleepFade() {
        #expect(WatchSleepTimer.fadeMultiplier(remaining: 60) == 1)
        #expect(WatchSleepTimer.fadeMultiplier(remaining: 5) == 0.5)
        #expect(WatchSleepTimer.fadeMultiplier(remaining: 0) == 0)
    }

    @Test("Resume rewinds five seconds after a pause longer than five minutes")
    func resumeRewind() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(WatchResumeRewind.position(100, pausedAt: now.addingTimeInterval(-60), now: now) == 100)
        #expect(WatchResumeRewind.position(100, pausedAt: now.addingTimeInterval(-600), now: now) == 95)
        #expect(WatchResumeRewind.position(3, pausedAt: now.addingTimeInterval(-600), now: now) == 0)
        #expect(WatchResumeRewind.position(100, pausedAt: nil, now: now) == 100)
    }

    @Test("Book time left follows the speed; progress spans chapters")
    func bookTime() {
        let durations: [TimeInterval] = [100, 200, 300]
        #expect(WatchBookTime.remainingInBook(chapterDurations: durations, chapterIndex: 1, position: 50, rate: 1) == 450)
        #expect(WatchBookTime.remainingInBook(chapterDurations: durations, chapterIndex: 1, position: 50, rate: 1.5) == 300)
        #expect(WatchBookTime.bookProgress(chapterDurations: durations, chapterIndex: 1, position: 50) == 0.25)
        #expect(WatchBookTime.remainingInBook(chapterDurations: durations, chapterIndex: 9, position: 0, rate: 1) == 0)
    }

    @Test("Stall code matches Platterhead's format")
    func stallCode() {
        #expect(WatchStallCode.make(timeControlStatus: 1, reason: "AVPlayerWaitingToMinimizeStallsReason")
                == "stalled-1-ToMinimizeStalls")
        #expect(WatchStallCode.make(timeControlStatus: 1, reason: nil) == "stalled-1-none")
    }

    @Test("A classified problem carries its kind and code, and clears when playback moves on")
    func reducerProblem() {
        let start = WatchPlaybackSnapshot(eventToken: 1)
        let failed = WatchPlaybackReducer.reduce(start, event: .problem(.stalled, message: "m", code: "stalled-1-x"), token: 1)
        #expect(failed.failureKind == .stalled)
        #expect(failed.failureCode == "stalled-1-x")
        #expect(failed.phase == .failed("m"))
        let ticked = WatchPlaybackReducer.reduce(failed, event: .time(position: 3, duration: 10), token: 1)
        #expect(ticked.failureCode == "stalled-1-x", "a time tick must not clear the failure")
        let playing = WatchPlaybackReducer.reduce(failed, event: .playing, token: 1)
        #expect(playing.failureKind == nil && playing.failureCode == nil)
        let lost = WatchPlaybackReducer.reduce(start, event: .routeLost, token: 1)
        #expect(lost.failureKind == .noOutput)
    }

    @Test("Rate events normalise the snapshot rate")
    func reducerRate() {
        let next = WatchPlaybackReducer.reduce(WatchPlaybackSnapshot(eventToken: 2), event: .rate(1.234), token: 2)
        #expect(next.rate == 1.25)
    }

    @Test("Only the watch's own downloads can pause")
    func downloadPause() {
        #expect(WatchBookDownload(done: 1, total: 4, state: .downloading).canPause)
        #expect(!WatchBookDownload(done: 1, total: 4, state: .sendingFromPhone).canPause)
        #expect(WatchBookDownload(done: 1, total: 4, state: .downloading).fraction == 0.25)
        #expect(WatchBookDownload(done: 0, total: 0, state: .waitingForPhone).fraction == 0)
    }
}
