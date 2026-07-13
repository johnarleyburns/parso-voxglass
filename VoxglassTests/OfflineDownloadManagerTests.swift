import XCTest
@testable import Voxglass

@MainActor
final class OfflineDownloadManagerTests: XCTestCase {

    // MARK: - §7 cellular / Pro gate decision

    func testStartDecisionAllowsFreeTasteLimit() {
        // Free tier with 0 pins → starts (taste limit: 2 free pins).
        let decision = OfflineDownloadManager.startDecision(
            isPro: false, isCellular: false, cacheOnCellular: false, allowCellularOverride: false,
            freePinCount: 0
        )
        XCTAssertEqual(decision, .start, "Free tier gets 2 pin slots before Pro is required")
    }

    func testStartDecisionRequiresProWhenTasteLimitReached() {
        let decision = OfflineDownloadManager.startDecision(
            isPro: false, isCellular: false, cacheOnCellular: false, allowCellularOverride: false,
            freePinCount: 2
        )
        XCTAssertEqual(decision, .needsPro, "After 2 free pins, Pro is required")
    }

    func testStartDecisionPromptsOnCellularWhenToggleOff() {
        let decision = OfflineDownloadManager.startDecision(
            isPro: true, isCellular: true, cacheOnCellular: false, allowCellularOverride: false
        )
        XCTAssertEqual(decision, .needsCellularConfirmation)
    }

    func testStartDecisionStartsOnCellularWhenToggleOn() {
        let decision = OfflineDownloadManager.startDecision(
            isPro: true, isCellular: true, cacheOnCellular: true, allowCellularOverride: false
        )
        XCTAssertEqual(decision, .start)
    }

    func testStartDecisionStartsOnCellularWithOverride() {
        let decision = OfflineDownloadManager.startDecision(
            isPro: true, isCellular: true, cacheOnCellular: false, allowCellularOverride: true
        )
        XCTAssertEqual(decision, .start)
    }

    func testStartDecisionStartsOnWiFi() {
        let decision = OfflineDownloadManager.startDecision(
            isPro: true, isCellular: false, cacheOnCellular: false, allowCellularOverride: false
        )
        XCTAssertEqual(decision, .start)
    }

    // MARK: - §7 state derivation

    func testDerivedStateAllChaptersCompleteIsCached() {
        XCTAssertEqual(
            OfflineDownloadManager.derivedState(chapterComplete: [true, true, true], anyFailed: false),
            .cached
        )
    }

    func testDerivedStatePartialIsDownloading() {
        XCTAssertEqual(
            OfflineDownloadManager.derivedState(chapterComplete: [true, false, false], anyFailed: false),
            .downloading(progress: 1.0 / 3.0)
        )
    }

    func testDerivedStateNoneCompleteIsNotCached() {
        XCTAssertEqual(
            OfflineDownloadManager.derivedState(chapterComplete: [false, false], anyFailed: false),
            .notCached
        )
    }

    func testDerivedStateEmptyIsNotCached() {
        XCTAssertEqual(
            OfflineDownloadManager.derivedState(chapterComplete: [], anyFailed: false),
            .notCached
        )
    }

    func testDerivedStatePartialWithFailureIsFailed() {
        XCTAssertEqual(
            OfflineDownloadManager.derivedState(chapterComplete: [true, false], anyFailed: true),
            .failed
        )
    }

    // MARK: - §6/§7 stable cache keys

    func testAudioCacheKeyIsStableAcrossCalls() {
        let url = URL(string: "https://archive.org/download/item/01%20Chapter.mp3")!
        XCTAssertEqual(CachingResourceLoader.key(for: url), CachingResourceLoader.key(for: url))
    }

    func testAudioCacheKeyIsSHA256Hex() {
        let url = URL(string: "https://archive.org/download/item/01%20Chapter.mp3")!
        let key = CachingResourceLoader.key(for: url)
        XCTAssertTrue(key.hasSuffix("-mp3"))
        let hex = key.replacingOccurrences(of: "-mp3", with: "")
        XCTAssertEqual(hex.count, 64, "SHA256 hex digest is 64 characters")
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(key.hasPrefix("art_"), "Audio keys must not collide with artwork keys")
    }
}
