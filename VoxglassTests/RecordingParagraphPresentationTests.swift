import Foundation
import Testing
@testable import VoxglassCore

@Suite struct RecordingParagraphPresentationTests {
    @Test func recordAndRerecordUseNormalLeadingParagraphText() throws {
        let screen = try source("Voxglass/Features/Production/Discovery/NarrationFlowScreens.swift")
        let teleprompterStart = try #require(screen.range(of: "private func teleprompter(_ paragraph: FlowParagraph)"))
        let teleprompterEnd = try #require(
            screen.range(of: "private var errorCard", range: teleprompterStart.upperBound..<screen.endIndex)
        )
        let teleprompter = String(screen[teleprompterStart.lowerBound..<teleprompterEnd.lowerBound])

        #expect(teleprompter.contains("VStack(alignment: .leading"))
        #expect(teleprompter.contains(".scaledFont(size: 16)"))
        #expect(teleprompter.contains(".multilineTextAlignment(.leading)"))
        #expect(teleprompter.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(teleprompter.contains(".accessibilityIdentifier(\"record.teleprompter.text\")"))
        #expect(!(teleprompter.contains(".scaledFont(size: 22, weight: .semibold)")))
        #expect(!(teleprompter.contains(".multilineTextAlignment(.center)")))

        // ParagraphReviewView pushes this same RecordView for re-recording, so
        // both entry points stay on the presentation asserted above.
        let review = try source("Voxglass/Features/Production/Discovery/ParagraphReviewView.swift")
        #expect(review.contains("RecordView(model: model, paragraphID: id, fromReview: true)"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
