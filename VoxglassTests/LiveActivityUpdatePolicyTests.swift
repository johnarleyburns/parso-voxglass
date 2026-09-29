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
}
