import Testing
@testable import VoxglassCore

@Suite struct NarrationPhaseTests {
    @Test func phaseProgressesFromDraftToReady() {
        #expect(NarrationPhase(recorded: 0, approved: 0, total: 3, hasExport: false) == .draft)
        #expect(NarrationPhase(recorded: 1, approved: 0, total: 3, hasExport: false) == .recording(recorded: 1, total: 3))
        #expect(NarrationPhase(recorded: 3, approved: 1, total: 3, hasExport: false) == .review(pending: 2, total: 3))
        #expect(NarrationPhase(recorded: 3, approved: 3, total: 3, hasExport: false) == .package)
        #expect(NarrationPhase(recorded: 3, approved: 3, total: 3, hasExport: true) == .ready)
    }

    @Test func captionsUseParagraphAndTakeUnits() {
        #expect(NarrationPhase.recording(recorded: 2, total: 5).caption == "2 of 5 paragraphs recorded")
        #expect(NarrationPhase.review(pending: 2, total: 5).caption == "2 takes to review")
    }
}
