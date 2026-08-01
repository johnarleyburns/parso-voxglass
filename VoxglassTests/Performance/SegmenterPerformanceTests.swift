import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §19.3: the 10,000-paragraph re-import completes in < 2 s. The
/// document is built so every heading level is a real chapter boundary, so
/// chapter formation does not collapse (T32 regression guard).
///
/// Timing tests live in this dedicated `VoxglassPerformanceTests` target so
/// they run serially (`--no-parallel --filter VoxglassPerformanceTests`) and
/// never contend with the parallel logic suites for CPU.
@Suite(.serialized) struct SegmenterPerformanceTests {
    @Test func tenThousandParagraphReimportUnder2Seconds() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let blockCount = 10_000
        var plainText = ""
        var blocks: [ExtractedBlock] = []
        var offset = 0
        for i in 0..<blockCount {
            let text = "Chapter \(i / 100 + 1) paragraph \(i). " + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 2)
            let start = offset
            let separator = i > 0 ? "\n\n" : ""
            plainText += separator + text
            offset += separator.count + text.count
            let end = offset
            let kind: BlockKind = i % 100 == 0 ? .heading : .paragraph
            let level: Int? = i % 100 == 0 ? 1 : nil
            blocks.append(ExtractedBlock(kind: kind, text: text, sourceRange: start..<end, headingLevel: level))
        }
        let doc = ExtractedDocument(
            sections: [ExtractedSection(heading: "Book", blocks: blocks, sourceStart: 0)],
            plainText: plainText
        )

        let start = DispatchTime.now()
        let result = Segmenter().segment(doc, ids: ids, clock: clock)
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        #expect(result.chapters.count == blockCount / 100)
        #expect(result.stats.paragraphCount == blockCount)
        #expect(elapsedMS < 2_000, "10K re-import took \(elapsedMS) ms, budget is 2000 ms")
    }
}
