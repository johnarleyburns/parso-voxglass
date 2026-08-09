import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §10: the assignment plan for an imported audio file. Pure planning —
/// silence detection splits the decoded PCM and matches slices to paragraphs in
/// document order; the whole-file mode assigns everything to one paragraph.
@Suite struct AudioImportPlannerTests {

    /// Decoded PCM of `burstCount` speech bursts separated by quiet gaps, at a
    /// small sample rate so the test stays cheap.
    private static func speechSamples(burstCount: Int, rate: Double = 1000) -> [Float] {
        var samples: [Float] = []
        for _ in 0..<burstCount {
            for _ in 0..<Int(0.5 * rate) {
                samples.append(0.6 * Float(sin(Double(samples.count) * 0.1)))
            }
            for _ in 0..<Int(0.5 * rate) {
                samples.append(0.001)
            }
        }
        return samples
    }

    private static func ids(_ count: Int) -> [UUID] {
        let ids = SequentialIDGenerator()
        return (0..<count).map { _ in ids.next() }
    }

    @Test func wholeParagraphAssignsEntireFileToFirstTarget() {
        let samples = Self.speechSamples(burstCount: 3)
        let targets = Self.ids(5)
        let plan = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .wholeParagraph, targetParagraphIDs: targets
        )
        #expect(plan.mode == .wholeParagraph)
        #expect(plan.slices.count == 1)
        #expect(plan.slices[0].paragraphID == targets[0])
        #expect(plan.isFullyAssigned)
        #expect(plan.slices[0].startFrame == 0)
        #expect(plan.slices[0].frameCount == samples.count)
    }

    @Test func splitBySilenceMatchesSegmentsToParagraphsInOrder() {
        let samples = Self.speechSamples(burstCount: 4)
        let targets = Self.ids(4)
        let plan = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .splitBySilence, targetParagraphIDs: targets
        )
        #expect(plan.isFullyAssigned, "4 segments should match 4 paragraphs")
        #expect(plan.unmatchedSliceCount == 0)
        #expect(plan.slices.count >= 2)
        let expected: [UUID?] = targets.map(Optional.init)
        let actual: [UUID?] = plan.slices.map { $0.paragraphID }
        #expect(actual == expected)
    }

    @Test func splitBySilenceReportsUnmatchedSegmentsWhenMoreThanParagraphs() {
        let samples = Self.speechSamples(burstCount: 6)
        let targets = Self.ids(3)
        let plan = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .splitBySilence, targetParagraphIDs: targets
        )
        #expect(!plan.isFullyAssigned)
        #expect(plan.unmatchedSliceCount == plan.slices.count - 3)
        let expected: [UUID?] = targets.map(Optional.init)
        let actual: [UUID?] = plan.slices.prefix(3).map { $0.paragraphID }
        #expect(actual == expected)
        #expect(plan.slices.dropFirst(3).allSatisfy { $0.paragraphID == nil })
    }

    @Test func sequentialUsesTheSameDetectionButConfirmsBoundaries() {
        let samples = Self.speechSamples(burstCount: 4)
        let targets = Self.ids(4)
        let silence = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .splitBySilence, targetParagraphIDs: targets
        )
        let sequential = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .sequential, targetParagraphIDs: targets
        )
        #expect(sequential.slices.count == silence.slices.count)
        #expect(sequential.isFullyAssigned)
        let expected: [UUID?] = targets.map(Optional.init)
        let actual: [UUID?] = sequential.slices.map { $0.paragraphID }
        #expect(actual == expected)
    }

    @Test func emptyTargetsLeaveWholeFileUnmatched() {
        let samples = Self.speechSamples(burstCount: 2)
        let plan = AudioImportPlanner().plan(
            samples: samples, sampleRate: 1000, mode: .wholeParagraph, targetParagraphIDs: []
        )
        #expect(plan.unmatchedSliceCount == 1)
        #expect(plan.slices[0].paragraphID == nil)
    }
}
