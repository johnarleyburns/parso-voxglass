import Foundation
import Testing
@testable import VoxglassCore

@Suite struct PlatePaletteContrastTests {
    @Test func everyPlatePairMeetsReadableContrast() {
        for pair in PlatePaletteValues.pairs {
            #expect(contrast(pair.ink, pair.background) >= 4.5)
        }
    }

    private func contrast(_ foreground: PlateRGB, _ background: PlateRGB) -> Double {
        func luminance(_ color: PlateRGB) -> Double {
            func linear(_ component: Double) -> Double { component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
