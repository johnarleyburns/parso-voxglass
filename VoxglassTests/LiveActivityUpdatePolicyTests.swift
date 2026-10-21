import Foundation
import Testing
@testable import VoxglassCore

@Suite struct LiveActivityUpdatePolicyTests {
    private let bookID = UUID()

    private func content(
        elapsed: TimeInterval = 10,
        capturedAt: TimeInterval = 100,
        playing: Bool = true,
        rate: Float = 1,
        chapter: Int = 1,
        sleep: SleepState = .off
    ) -> LiveActivityContent {
        LiveActivityContent(bookID: bookID, title: "Book", author: "Author", narrator: nil,
                            chapterTitle: "Chapter", chapterIndex: chapter, chapterCount: 3,
                            isPlaying: playing, rate: rate, chapterElapsed: elapsed,
                            chapterDuration: 600, bookRemaining: 1_200, sleep: sleep,
                            capturedAt: Date(timeIntervalSince1970: capturedAt))
    }

    @Test func pushesMeaningfulChanges() {
        let previous = content()
        #expect(LiveActivityUpdatePolicy.shouldPush(previous: previous, next: content(chapter: 2)))
        #expect(LiveActivityUpdatePolicy.shouldPush(previous: previous, next: content(playing: false)))
        #expect(LiveActivityUpdatePolicy.shouldPush(previous: previous, next: content(rate: 1.5)))
        #expect(LiveActivityUpdatePolicy.shouldPush(previous: previous, next: content(sleep: .endOfChapter)))
        #expect(LiveActivityUpdatePolicy.shouldPush(previous: previous, next: content(elapsed: 30, capturedAt: 110)))
    }

    @Test func ignoresConsistentPlayheadDrift() {
        #expect(!LiveActivityUpdatePolicy.shouldPush(previous: content(), next: content(elapsed: 20, capturedAt: 110)))
    }

    @Test func progressIntervalIsRateAware() {
        let one = LiveActivityUpdatePolicy.progressInterval(for: content(rate: 1))!
        let fast = LiveActivityUpdatePolicy.progressInterval(for: content(rate: 3.5))!
        #expect(one.lowerBound == Date(timeIntervalSince1970: 90))
        #expect(one.upperBound == Date(timeIntervalSince1970: 690))
        #expect(fast.lowerBound == Date(timeIntervalSince1970: 100 - 10 / 3.5))
        #expect(abs(fast.upperBound.timeIntervalSince1970 - (100 - 10 / 3.5 + 600 / 3.5)) < 0.0001)
    }

    @Test func staleDatesCoverPausedAndPlayingStates() {
        let playing = LiveActivityUpdatePolicy.staleDate(for: content())!
        let paused = LiveActivityUpdatePolicy.staleDate(for: content(playing: false))!
        #expect(playing == Date(timeIntervalSince1970: 750))
        #expect(paused == Date(timeIntervalSince1970: 1_000))
    }

    @Test func unknownPlayerTimesNeverReachTheLiveActivityAsNaN() {
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: .nan, duration: 600) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: 10, duration: .nan) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: 10, duration: nil) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: 10, duration: 0) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: .infinity, duration: 600) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: 700, duration: 600) == 1)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: -5, duration: 600) == 0)
        #expect(LiveActivityUpdatePolicy.chapterFraction(elapsed: 150, duration: 600) == 0.25)
        #expect(LiveActivityUpdatePolicy.bookRemaining(.nan) == nil)
        #expect(LiveActivityUpdatePolicy.bookRemaining(-1) == nil)
        #expect(LiveActivityUpdatePolicy.bookRemaining(90) == 90)
    }

    @Test func aNaNPlayheadHasNoProgressIntervalInsteadOfTrapping() {
        #expect(LiveActivityUpdatePolicy.progressInterval(for: content(elapsed: .nan)) == nil)
        #expect(LiveActivityUpdatePolicy.staleDate(for: content(elapsed: .nan)) != nil)
    }

    @Test func activityContentNormalizesTransientPlayerNumbers() {
        #expect(LiveActivityUpdatePolicy.safeRate(.nan) == 1)
        #expect(LiveActivityUpdatePolicy.safeRate(.infinity) == 1)
        #expect(LiveActivityUpdatePolicy.safeRate(1.5) == 1.5)
        #expect(LiveActivityUpdatePolicy.safeElapsed(.infinity) == 0)
        #expect(LiveActivityUpdatePolicy.safeElapsed(-2) == 0)
    }
}

@Suite struct LiveActivityLifecyclePolicyTests {
    private typealias Snap = LiveActivityLifecyclePolicy.Snapshot
    private let a = UUID(), b = UUID(), c = UUID()

    private func content(_ id: UUID, playing: Bool = true) -> LiveActivityContent {
        LiveActivityContent(bookID: id, title: "T", author: "A", narrator: nil, chapterTitle: "C",
                            chapterIndex: 1, chapterCount: 3, isPlaying: playing, rate: 1,
                            chapterElapsed: 0, chapterDuration: 60, bookRemaining: 100, sleep: .off,
                            capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func switchingBooksEndsOldAndCreatesNew() {
        let plan = LiveActivityLifecyclePolicy.plan(existing: [Snap(id: "1", bookID: a)], content: content(b), enabled: true)
        #expect(plan == .init(reuse: nil, end: ["1"], create: true))
    }

    @Test func sameBookReusesActivity() {
        let plan = LiveActivityLifecyclePolicy.plan(existing: [Snap(id: "2", bookID: b)], content: content(b), enabled: true)
        #expect(plan == .init(reuse: "2", end: [], create: false))
    }

    @Test func rapidSwitchLeavesOnlyLatest() {
        let plan = LiveActivityLifecyclePolicy.plan(
            existing: [Snap(id: "1", bookID: a), Snap(id: "2", bookID: b)], content: content(c), enabled: true)
        #expect(plan == .init(reuse: nil, end: ["1", "2"], create: true))
    }

    @Test func duplicatesOfSameBookAreEnded() {
        let plan = LiveActivityLifecyclePolicy.plan(
            existing: [Snap(id: "1", bookID: b), Snap(id: "2", bookID: b)], content: content(b), enabled: true)
        #expect(plan == .init(reuse: "1", end: ["2"], create: false))
    }

    @Test func restoredActivityForOtherBookIsReplaced() {
        let plan = LiveActivityLifecyclePolicy.plan(existing: [Snap(id: "r", bookID: a)], content: content(b), enabled: true)
        #expect(plan.end == ["r"] && plan.create)
    }

    @Test func pausedRestoredSessionDoesNotCreate() {
        let none = LiveActivityLifecyclePolicy.plan(existing: [], content: content(b, playing: false), enabled: true)
        #expect(none == .init(reuse: nil, end: [], create: false))
        let other = LiveActivityLifecyclePolicy.plan(existing: [Snap(id: "1", bookID: a)], content: content(b, playing: false), enabled: true)
        #expect(other == .init(reuse: nil, end: ["1"], create: false))
    }

    @Test func disablingOrClearingEndsEverything() {
        let existing = [Snap(id: "1", bookID: a)]
        #expect(LiveActivityLifecyclePolicy.plan(existing: existing, content: content(a), enabled: false)
                == .init(reuse: nil, end: ["1"], create: false))
        #expect(LiveActivityLifecyclePolicy.plan(existing: existing, content: nil, enabled: true)
                == .init(reuse: nil, end: ["1"], create: false))
    }
}
