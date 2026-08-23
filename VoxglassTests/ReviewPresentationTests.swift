import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ReviewPresentationTests {
    @Test func chapterTextUsesItsOwnWrappedLeadingCard() throws {
        let screen = try source("Voxglass/Features/Production/Discovery/NarrationFlowScreens.swift")
        let rowStart = try #require(screen.range(of: "private func row(_ paragraph: FlowParagraph)"))
        let rowEnd = try #require(screen.range(of: "private func checkboxSymbol", range: rowStart.upperBound..<screen.endIndex))
        let row = String(screen[rowStart.lowerBound..<rowEnd.lowerBound])

        #expect(row.contains(".multilineTextAlignment(.leading)"))
        #expect(row.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(row.contains(".glassSurface(cornerRadius: 12)"))
        #expect(row.contains(".accessibilityIdentifier(\"review.chapter.textContainer.\\(index)\")"))
        #expect(!(row.contains(".lineLimit(2)")))

        let card = try #require(row.range(of: "review.chapter.textContainer"))
        let approval = try #require(row.range(of: "review.row.approve"))
        #expect(card.lowerBound < approval.lowerBound)
    }

    @Test func approvalControlsUseTheSameTogglePath() throws {
        let flow = try source("Voxglass/Features/Production/Discovery/NarrationFlow.swift")
        let detail = try source("Voxglass/Features/Production/Discovery/ParagraphReviewView.swift")
        let review = try source("Voxglass/Features/Production/Discovery/NarrationFlowScreens.swift")

        #expect(flow.contains("func toggleApproval(for id: UUID)"))
        #expect(detail.contains("model.toggleApproval(for: currentID)"))
        #expect(review.contains("case .approved:\n                        model.toggleApproval(for: paragraph.id)"))
        #expect(flow.contains("approved == project.totalCount"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }
}
