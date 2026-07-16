import XCTest
@testable import VoxglassCore

final class CarPlayProgressDetailTests: XCTestCase {

    func testProgressDetailFinished() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 10, chapterTitle: "Ch 1", position: 1800, chapterDuration: 1800, isFinished: true)
        XCTAssertEqual(CarPlayMenuBuilder.progressDetail(p), "Finished")
    }

    func testProgressDetailNearEndOfChapter() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 24, chapterTitle: "Ch 5", position: 1780, chapterDuration: 1800)
        XCTAssertEqual(CarPlayMenuBuilder.progressDetail(p), "Finishing Ch 5")
    }

    func testProgressDetailWithBookRemaining() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 20, chapterTitle: "Ch 1", position: 300, chapterDuration: 1800, bookRemaining: 14400)
        XCTAssertTrue(CarPlayMenuBuilder.progressDetail(p).contains("left"))
    }

    func testProgressDetailWithChapterRemainingOnly() {
        let p = CarPlayProgress(chapterIndex: 0, chapterCount: 5, chapterTitle: "Ch 1", position: 300, chapterDuration: 1800)
        let detail = CarPlayMenuBuilder.progressDetail(p)
        XCTAssertTrue(detail.contains("left in chapter"))
    }

    func testProgressDetailWithNothingKnown() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 24, chapterTitle: "Ch 5", position: 300)
        XCTAssertEqual(CarPlayMenuBuilder.progressDetail(p), "Ch 5 of 24")
    }

    func testProgressDerive() {
        let titles = ["Ch 1", "Ch 2"]
        let durations: [TimeInterval?] = [1800, 1800]
        let p = CarPlayProgress.derive(cumulativePosition: 2400, isFinished: false, chapterTitles: titles, chapterDurations: durations)
        XCTAssertEqual(p?.chapterIndex, 1)
        XCTAssertEqual(p?.position ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(p?.bookRemaining ?? -1, 1200, accuracy: 0.001)
    }

    func testProgressDeriveFinished() {
        let titles = ["Ch 1", "Ch 2"]
        let durations: [TimeInterval?] = [1800, 1800]
        let p = CarPlayProgress.derive(cumulativePosition: 3600, isFinished: true, chapterTitles: titles, chapterDurations: durations)
        XCTAssertEqual(p?.isFinished, true)
        XCTAssertEqual(p?.fraction, 1.0)
    }

    func testProgressFractionMidway() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 10, chapterTitle: "Ch 5", position: 900, chapterDuration: 1800)
        XCTAssertEqual(p.fraction, 0.45, accuracy: 0.01)
    }

    func testProgressFractionFinished() {
        let p = CarPlayProgress(chapterIndex: 4, chapterCount: 10, chapterTitle: "Ch 5", position: 1800, chapterDuration: 1800, isFinished: true)
        XCTAssertEqual(p.fraction, 1.0)
    }

    // MARK: - CarPlayTimeFormat (used by progressDetail)

    func testTimeFormatHours() {
        XCTAssertEqual(CarPlayTimeFormat.compact(8040), "2h 14m")
    }

    func testTimeFormatMinutes() {
        XCTAssertEqual(CarPlayTimeFormat.compact(1080), "18 min")
    }

    func testTimeFormatSeconds() {
        XCTAssertEqual(CarPlayTimeFormat.compact(48), "48s")
    }

    func testTimeFormatZero() {
        XCTAssertEqual(CarPlayTimeFormat.compact(0), "0s")
    }
}
