import Testing
@testable import VoxglassCore

@Suite struct SilenceDetectorTests {

    @Test func singleSilentBufferDoesNotTrigger() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        _ = detector.process(rms: 0.0)
        #expect(detector.state == .speech)
    }

    @Test func consecutiveSilentBuffersTrigger() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        for _ in 0..<2 {
            _ = detector.process(rms: 0.0)
            #expect(detector.state == .speech)
        }
        _ = detector.process(rms: 0.0)
        #expect(detector.state == .silent)
    }

    @Test func speechReturnsImmediately() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        for _ in 0..<3 {
            _ = detector.process(rms: 0.0)
        }
        #expect(detector.state == .silent)
        _ = detector.process(rms: 0.5)
        #expect(detector.state == .speech)
    }

    @Test func noFlapping() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 3)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.5)
        #expect(detector.state == .speech)
    }

    @Test func reset() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 2)
        _ = detector.process(rms: 0.0)
        _ = detector.process(rms: 0.0)
        #expect(detector.state == .silent)
        detector.reset()
        #expect(detector.state == .speech)
        _ = detector.process(rms: 0.0)
        #expect(detector.state == .speech)
    }

    @Test func realisticNoiseFloorReadsAsSilence() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        for _ in 0..<5 {
            _ = detector.process(rms: 0.01)
        }
        #expect(detector.state == .silent)  // Hiss at ~0.01 should read as silence at the new 0.02 threshold
    }

    @Test func speechLevelAboveNoiseFloorDoesNotTriggerSilence() {
        let detector = SilenceDetector(threshold: 0.02, consecutiveFramesRequired: 5)
        for _ in 0..<10 {
            _ = detector.process(rms: 0.05)
        }
        #expect(detector.state == .speech)  // Speech at ~0.05 should not trigger silence
    }
}
