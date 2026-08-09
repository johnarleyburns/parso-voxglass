import SwiftUI

/// Narration-surface color tokens (§15.3 rule 7: colors come from the
/// DesignSystem — no color literals in feature code). The narration UI needs a
/// warmer, book-studio accent set on top of the glass `Palette`; every value
/// below is a named token so feature code never spells a hex literal.
enum NarrationPalette {
    /// Dark espresso text on brass/accent fills (the "Continue"/"Record" buttons).
    static let espresso = Color(hex: 0x21170B)
    /// Soft brass used for flagged / drift / needs-pickup chips.
    static let brassSoft = Color(hex: 0xE6B877)
    /// Mid brass for the record chip.
    static let brassMid = Color(hex: 0xE0A44F)
    /// Cream label on a selected filter chip.
    static let cream = Color(hex: 0xF6F2EA)
    /// Warm parchment text on the forest gradients.
    static let creamWarm = Color(hex: 0xF8E8C7)
    /// Tan note text.
    static let tan = Color(hex: 0xE6C79C)
    /// Near-black foreground on a selected filter chip.
    static let nearBlack = Color(hex: 0x111111)
    /// Dark ink panel fills (meters, health cards).
    static let panelInk = Color(hex: 0x0F1316)
    /// Forest gradient start.
    static let forestDeep = Color(hex: 0x101A14)
    /// Forest gradient end (record-ready surfaces).
    static let forest = Color(hex: 0x2F5A3E)
    /// Mint for ready / success chips.
    static let mint = Color(hex: 0x72D59F)
    /// Sky blue for the Internet Archive chip.
    static let sky = Color(hex: 0x8FD0FF)
    /// Soft sky for retail text.
    static let skySoft = Color(hex: 0x9FC3FF)
    /// Periwinkle for the retail chip border.
    static let periwinkle = Color(hex: 0x7896DC)
    /// Lavender for the catalogue-gap category chip.
    static let lavender = Color(hex: 0xC9B6FF)
    /// Olive for warm gradient ends.
    static let olive = Color(hex: 0x5A4A2B)
    /// Sand for warm gradient ends (catalogue cards).
    static let sand = Color(hex: 0x6B5432)
    /// Deep tan for warm gradient starts.
    static let tanDeep = Color(hex: 0x2A2417)
    /// Umber for warm gradient starts (catalogue cards).
    static let umber = Color(hex: 0x3A2F1C)
}
