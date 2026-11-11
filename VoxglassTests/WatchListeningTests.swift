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

@Suite("Watch continue-listening widget state (redesign A2)")
struct WatchContinueListeningStateTests {
    @Test("Round-trips, reloads only on real changes, and ranks relevance")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "continue-\(UUID().uuidString)"))
        let state = WatchContinueListeningState(bookTitle: "Moby Dick", chapterIndex: 2, chapterTitle: "Loomings",
                                                progress: 0.12, remainingInBook: 3_600, isPlaying: false,
                                                anchorDate: Date(timeIntervalSince1970: 0))
        WatchContinueListeningStore.save(state, defaults: defaults)
        #expect(WatchContinueListeningStore.load(defaults: defaults) == state)
        var tick = state
        tick.remainingInBook -= 5
        #expect(!tick.differsStructurally(from: state))
        tick.isPlaying = true
        #expect(tick.differsStructurally(from: state))
        #expect(tick.relevance(at: Date()) == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(state.relevance(at: Date(timeIntervalSince1970: 21 * 3600), calendar: calendar) == 0.6)
        #expect(state.relevance(at: Date(timeIntervalSince1970: 9 * 3600), calendar: calendar) == 0.2)
    }
}

@Suite("Watch resume resolver")
struct WatchResumeResolverTests {
    private func chapters(markerAt: Int? = nil, position: Double = 0, indices: [Int] = [0, 1, 2, 3, 4]) -> [WatchChapterDTO] {
        indices.enumerated().map { offset, index in
            WatchChapterDTO(id: .init("c\(offset)"), index: index, title: "C\(offset)", duration: 100,
                            resumePosition: offset == markerAt ? position : nil)
        }
    }

    @Test func phoneLaterChapterBeatsLocalBeginning() {
        let c = chapters(markerAt: 3, position: 42)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[0].id: 0]) == .init(chapterIndex: 3, position: 42))
    }

    @Test func fartherLocalWatchProgressBeatsBehindPhoneMarker() {
        let c = chapters(markerAt: 1, position: 90)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[2].id: 4]) == .init(chapterIndex: 2, position: 4))
    }

    @Test func sameChapterMaxWins() {
        let c = chapters(markerAt: 2, position: 10)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[2].id: 30]).position == 30)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[2].id: 5]).position == 10)
    }

    @Test func localZeroInLaterChapterIsValid() {
        let c = chapters(markerAt: 1, position: 50)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[3].id: 0]) == .init(chapterIndex: 3, position: 0))
    }

    @Test func singleAndNoSources() {
        let c = chapters(markerAt: 3, position: 42)
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [:]) == .init(chapterIndex: 3, position: 42))
        let n = chapters()
        #expect(WatchResumeResolver.resolve(chapters: n, localPositions: [n[1].id: 7]) == .init(chapterIndex: 1, position: 7))
        #expect(WatchResumeResolver.resolve(chapters: n, localPositions: [:]) == .init(chapterIndex: 0, position: 0))
        #expect(WatchResumeResolver.resolve(chapters: [], localPositions: [:]) == .init(chapterIndex: 0, position: 0))
    }

    @Test func invalidValuesNormalize() {
        let n = chapters()
        #expect(WatchResumeResolver.resolve(chapters: n, localPositions: [n[1].id: .nan]) == .init(chapterIndex: 1, position: 0))
        #expect(WatchResumeResolver.resolve(chapters: n, localPositions: [n[1].id: -5]) == .init(chapterIndex: 1, position: 0))
    }

    @Test func nonContiguousIndicesUseArrayOrder() {
        let c = chapters(markerAt: 1, position: 8, indices: [10, 20, 30])
        #expect(WatchResumeResolver.resolve(chapters: c, localPositions: [c[0].id: 99]) == .init(chapterIndex: 1, position: 8))
    }

    @Test func positionStoreSnapshotIsPerBook() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("p.json")
        let store = WatchPlaybackPositionStore(url: url)
        try await store.save(4, bookID: "a", chapterID: "x")
        try await store.save(9, bookID: "b", chapterID: "y")
        #expect(await store.positions(for: "a") == ["x": 4])
    }
}
