import Testing
@testable import VoxglassCore

@Suite struct CarPlayNowPlayingModelTests {

    @Test func rateTitleReflectsCurrentRate() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.5,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(config.rateTitle == "1.5\u{00D7}")
    }

    @Test func sleepButtonActiveWhenTimerArmedEndOfChapter() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .endOfChapter, sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(config.sleepActive)
        #expect(config.sleepTitle == "Ch. end")
    }

    @Test func sleepButtonActiveWhenTimerArmedThirtyMin() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .duration(1800), sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(config.sleepActive)
        #expect(config.sleepTitle == "30 min")
    }

    @Test func sleepButtonInactiveShowsSleep() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(!(config.sleepActive))
        #expect(config.sleepTitle == "Sleep")
    }

    @Test func carPlaySleepOptionsLeadWithEndOfChapterAndTrimDurations() {
        let options = CarPlayNowPlayingModel.sleepOptions
        #expect(options == [.endOfChapter, .duration(1800), .duration(3600), .off])
    }

    @Test func chaptersHiddenForSingleChapterBook() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 1, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(!(config.showsChapters))
        #expect(!(config.isUpNextChapters))
    }

    @Test func chaptersShownForMultiChapterBook() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 10, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: true
        )
        #expect(config.showsChapters)
        #expect(config.isUpNextChapters)
    }

    @Test func bookmarkHiddenWithoutBookmarkStore() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: true, chapterCount: 5, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: false
        )
        #expect(!(config.showsBookmark))
    }

    @Test func noConfigWithoutSession() {
        let config = CarPlayNowPlayingModel.config(
            hasSession: false, chapterCount: 0, rate: 1.0,
            sleepMode: .off, sleepRemaining: nil, hasBookmarkStore: false
        )
        #expect(!(config.showsRateButton))
        #expect(!(config.showsBookmark))
        #expect(!(config.showsChapters))
    }
}
