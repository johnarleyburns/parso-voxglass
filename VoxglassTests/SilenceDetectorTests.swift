import XCTest
@testable import Voxglass

final class SilenceDetectorTests: XCTestCase {

    func testSingleSilentBufferDoesNotTrigger() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        _ = detector.process(rms: 0.0)
        XCTAssertEqual(detector.state, .speech)
    }

    func testConsecutiveSilentBuffersTrigger() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        for _ in 0..<2 {
            _ = detector.process(rms: 0.0)
            XCTAssertEqual(detector.state, .speech)
        }
        _ = detector.process(rms: 0.0)
        XCTAssertEqual(detector.state, .silent)
    }

    func testSpeechReturnsImmediately() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        for _ in 0..<3 {
            _ = detector.process(rms: 0.0)
        }
        XCTAssertEqual(detector.state, .silent)
        _ = detector.process(rms: 0.5)
        XCTAssertEqual(detector.state, .speech)
    }

    func testNoFlapping() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        XCTAssertEqual(detector.state, .speech)
    }

    func testReset() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 2)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.0)
        XCTAssertEqual(detector.state, .silent)
        detector.reset()
        XCTAssertEqual(detector.state, .speech)
        _ = detector.process(rms: 0.0)
        XCTAssertEqual(detector.state, .speech)
    }

    func testRealisticNoiseFloorReadsAsSilence() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        for _ in 0..<5 {
            _ = detector.process(rms: 0.01)
        }
        XCTAssertEqual(detector.state, .silent, "Hiss at ~0.01 should read as silence at the new 0.02 threshold")
    }

    func testSpeechLevelAboveNoiseFloorDoesNotTriggerSilence() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        for _ in 0..<10 {
            _ = detector.process(rms: 0.05)
        }
        XCTAssertEqual(detector.state, .speech, "Speech at ~0.05 should not trigger silence")
    }
}
