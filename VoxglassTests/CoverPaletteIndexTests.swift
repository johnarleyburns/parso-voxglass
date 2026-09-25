import Testing
@testable import VoxglassCore

@Suite struct CoverPaletteIndexTests {
    @Test func normalizationMakesArticleAndWhitespaceStable() {
        #expect(CoverPaletteIndex.index(title: "  The   Odyssey ", author: "Homer") == CoverPaletteIndex.index(title: "Odyssey", author: "Homer"))
        #expect(CoverPaletteIndex.index(title: "The Odyssey", author: "Homer") == CoverPaletteIndex.index(title: "The Odyssey", author: "Homer"))
    }

    @Test func indexIsAlwaysWithinPalette() {
        for title in ["A", "The Time Machine", "Les Misérables", ""] {
            #expect((0..<8).contains(CoverPaletteIndex.index(title: title, author: nil)))
        }
    }
}
