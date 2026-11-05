import Testing
@testable import VoxglassCore

@Suite struct ReadWithAIDurationEstimateTests {
    @Test func normalRateEstimateMatchesSpeechProgressModel() {
        let text = String(repeating: "a", count: 140)
        #expect(ReadWithAIDurationEstimate.duration(for: text) == 10)
    }

    @Test func fasterRateShortensEstimate() {
        let text = String(repeating: "a", count: 140)
        #expect(ReadWithAIDurationEstimate.duration(for: text, rate: 2) == 5)
    }
}
