import Testing
import Foundation
@testable import VoxglassCore

@Suite struct CarPlayProgressDetailTests {

    @Test func progressDetailFinished() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 10, chapterTitle: "Ch 1", position: 1800, chapterDuration: 1800, isFinished: true)
        #expect(CarPlayMenuBuilder.progressDetail(p) == "Finished")
    }

    @Test func progressDetailNearEndOfChapter() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 24, chapterTitle: "Ch 5", position: 1780, chapterDuration: 1800)
        #expect(CarPlayMenuBuilder.progressDetail(p) == "Finishing Ch 5")
    }

    @Test func progressDetailWithBookRemaining() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 20, chapterTitle: "Ch 1", position: 300, chapterDuration: 1800, bookRemaining: 14400)
        #expect(CarPlayMenuBuilder.progressDetail(p).contains("left"))
    }

    @Test func progressDetailWithChapterRemainingOnly() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 5, chapterTitle: "Ch 1", position: 300, chapterDuration: 1800)
        let detail = CarPlayMenuBuilder.progressDetail(p)
        #expect(detail.contains("left in chapter"))
    }

    @Test func progressDetailWithNothingKnown() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 24, chapterTitle: "Ch 5", position: 300)
        #expect(CarPlayMenuBuilder.progressDetail(p) == "Ch 5 of 24")
    }

    @Test func progressDerive() {
        let titles = ["Ch 1", "Ch 2"]
        let durations: [TimeInterval?] = [1800, 1800]
        let p = CarPlayProgress.derive(cumulativePosition: 2400, isFinished: false, chapterTitles: titles, chapterDurations: durations)
        #expect(p?.chapterIndex == 1)
        #expect(abs((p?.position ?? -1) - (600)) <= 0.001)
        #expect(abs((p?.bookRemaining ?? -1) - (1200)) <= 0.001)
    }

    @Test func progressDeriveFinished() {
        let titles = ["Ch 1", "Ch 2"]
        let durations: [TimeInterval?] = [1800, 1800]
        let p = CarPlayProgress.derive(cumulativePosition: 3600, isFinished: true, chapterTitles: titles, chapterDurations: durations)
        #expect(p?.isFinished == true)
        #expect(p?.fraction == 1.0)
    }

    @Test func progressFractionMidway() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 10, chapterTitle: "Ch 5", position: 900, chapterDuration: 1800)
        #expect(abs((p.fraction) - (0.45)) <= 0.01)
    }

    @Test func progressFractionFinished() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 10, chapterTitle: "Ch 5", position: 1800, chapterDuration: 1800, isFinished: true)
        #expect(p.fraction == 1.0)
    }

    // MARK: - CarPlayTimeFormat (used by progressDetail)

    @Test func timeFormatHours() {
        #expect(CarPlayTimeFormat.compact(8040) == "2h 14m")
    }

    @Test func timeFormatMinutes() {
        #expect(CarPlayTimeFormat.compact(1080) == "18 min")
    }

    @Test func timeFormatSeconds() {
        #expect(CarPlayTimeFormat.compact(48) == "48s")
    }

    @Test func timeFormatZero() {
        #expect(CarPlayTimeFormat.compact(0) == "0s")
    }
}
