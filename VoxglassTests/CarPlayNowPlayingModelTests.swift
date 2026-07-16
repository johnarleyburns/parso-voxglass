import XCTest
@testable import VoxglassCore

final class CarPlayNowPlayingModelTests: XCTestCase {

    func testRateTitleReflectsCurrentRate() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.5,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertEqual(config.rateTitle, "1.5\u{00D7}")
    }

    func testSleepButtonActiveWhenTimerArmedEndOfChapter() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .endOfChapter, sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertTrue(config.sleepActive)
        XCTAssertEqual(config.sleepTitle, "Ch. end")
    }

    func testSleepButtonActiveWhenTimerArmedThirtyMin() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .duration(1800), sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertTrue(config.sleepActive)
        XCTAssertEqual(config.sleepTitle, "30 min")
    }

    func testSleepButtonInactiveShowsSleep() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertFalse(config.sleepActive)
        XCTAssertEqual(config.sleepTitle, "Sleep")
    }

    func testCarPlaySleepOptionsLeadWithEndOfChapterAndTrimDurations() {
        let options = CarPlayNowPlayingModel.sleepOptions
        XCTAssertEqual(options, [.endOfChapter, .duration(1800), .duration(3600), .off])
    }

    func testChaptersHiddenForSingleChapterBook() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 1, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertFalse(config.showsChapters)
        XCTAssertFalse(config.isUpNextChapters)
    }

    func testChaptersShownForMultiChapterBook() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 10, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        XCTAssertTrue(config.showsChapters)
        XCTAssertTrue(config.isUpNextChapters)
    }

    func testBookmarkHiddenWithoutBookmarkStore() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: false
        )
        XCTAssertFalse(config.showsBookmark)
    }

    func testNoConfigWithoutSession() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: false, chapterCount: 0, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: false
        )
        XCTAssertFalse(config.showsRateButton)
        XCTAssertFalse(config.showsBookmark)
        XCTAssertFalse(config.showsChapters)
    }
}
