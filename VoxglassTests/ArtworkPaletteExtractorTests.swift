import Testing
@testable import VoxglassCore

@Suite struct ArtworkPaletteExtractorTests {
    @Test func extractionIsDeterministicAndPreservesDominantColor() {
        let pixels: [UInt8] = Array(repeating: UInt8(0), count: 8 * 8 * 4).enumerated().map { index, _ in
            switch index % 4 { case 0: 180; case 1: 40; case 2: 30; default: 255 }
        }
        let first = ArtworkPaletteExtractor.extract(rgba8: pixels, width: 8, height: 8)
        let second = ArtworkPaletteExtractor.extract(rgba8: pixels, width: 8, height: 8)
        #expect(first == second)
        #expect(first.dominant.red > first.dominant.green)
    }
}
