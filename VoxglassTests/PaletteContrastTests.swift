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
                #expect(PaletteSpec.contrast(token.light, surface.light) >= 4.5)
                #expect(PaletteSpec.contrast(token.lightHighContrast, surface.lightHighContrast) >= 4.5)
            }
        }
    }

    @Test func secondaryTextIsBrighterThanTertiaryText() {
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.standard, PaletteSpec.bg.standard) >
                PaletteSpec.contrast(PaletteSpec.ink3.standard, PaletteSpec.bg.standard))
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.highContrast, PaletteSpec.bg.highContrast) >
                PaletteSpec.contrast(PaletteSpec.ink3.highContrast, PaletteSpec.bg.highContrast))
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.light, PaletteSpec.bg.light) >
                PaletteSpec.contrast(PaletteSpec.ink3.light, PaletteSpec.bg.light))
        #expect(PaletteSpec.contrast(PaletteSpec.ink2.lightHighContrast, PaletteSpec.bg.lightHighContrast) >
                PaletteSpec.contrast(PaletteSpec.ink3.lightHighContrast, PaletteSpec.bg.lightHighContrast))
    }

    @Test func brassHasReadableOnColor() {
        #expect(PaletteSpec.contrast(0x21170B, PaletteSpec.brass.standard) >= 4.5)
        #expect(PaletteSpec.contrast(0x21170B, PaletteSpec.brass.highContrast) >= 4.5)
        #expect(PaletteSpec.contrast(0xFFFFFF, PaletteSpec.brass.light) >= 4.5)
        #expect(PaletteSpec.contrast(0xFFFFFF, PaletteSpec.brass.lightHighContrast) >= 4.5)
    }
}
