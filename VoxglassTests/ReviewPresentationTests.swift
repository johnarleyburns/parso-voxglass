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

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }
}
