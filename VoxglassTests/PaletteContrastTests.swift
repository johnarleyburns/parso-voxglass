import Testing
@testable import VoxglassCore

@Suite struct PaletteContrastTests {
    @Test func textTokensMeetWCAGAAOnEverySurface() {
        let surfaces = [PaletteSpec.bg, PaletteSpec.surface, PaletteSpec.raised]
        let text = [PaletteSpec.ink, PaletteSpec.ink2, PaletteSpec.ink3, PaletteSpec.brass]
        for surface in surfaces {
            for token in text {
                #expect(PaletteSpec.contrast(token.standard, surface.standard) >= 4.5)
                #expect(PaletteSpec.contrast(token.highContrast, surface.highContrast) >= 4.5)
            }
        }
    }

    @Test func secondaryTextIsBrighterThanTertiaryText() {
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.standard, PaletteSpec.bg.standard) >
                PaletteSpec.contrast(PaletteSpec.ink3.standard, PaletteSpec.bg.standard))
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.highContrast, PaletteSpec.bg.highContrast) >
                PaletteSpec.contrast(PaletteSpec.ink3.highContrast, PaletteSpec.bg.highContrast))
    }

    @Test func brassHasReadableOnColor() {
        #expect(PaletteSpec.contrast(0x21170B, PaletteSpec.brass.standard) >= 4.5)
        #expect(PaletteSpec.contrast(0x21170B, PaletteSpec.brass.highContrast) >= 4.5)
    }
}
