import SwiftUI

/// Discovery-surface color tokens for the Mac library's "Start a Narration"
/// section (§8.4, §15.3 rule 7: colors come from the DesignSystem — no color
/// literals in feature code). Gate G-P4 is extended to `VoxglassMac/` in U0;
/// this is that surface's named-token source.
///
/// This is **not** the same Swift type as the iOS app's
/// `Voxglass/DesignSystem/NarrationPalette.swift` — that file lives in the
/// `Voxglass` app target, which `VoxglassMac` cannot import (DesignSystem is
/// not part of `VoxglassCore`). The two palettes happen to share a visual
/// language (this tree predates the iOS palette's introduction) but are
/// intentionally separate values here rather than force-matched to iOS's
/// hexes. Unifying them into one shared, Core-adjacent DesignSystem module is
/// a real follow-up, not attempted in U0.
enum MacPalette {
    /// Mint for the "open project needs readers" signal chip.
    static let mint = Color(hex: 0x72D59F)
    /// Soft brass for the "proof-listener needed" signal chip.
    static let brassSoft = Color(hex: 0xE6B877)
    /// Mid brass for the featured/submittable accents and the "book of the
    /// month" call to action.
    static let brassMid = Color(hex: 0xE0BE7F)
    /// Lavender for the "needs a narrator" (catalogue gap) signal chip.
    static let lavender = Color(hex: 0xC9B6FF)
    /// Forest gradient start (book-of-the-month cover placeholder).
    static let forestDeep = Color(hex: 0x101A14)
    /// Forest gradient middle.
    static let forest = Color(hex: 0x2F5A3E)
    /// Forest gradient end (warm highlight).
    static let forestGold = Color(hex: 0xC7B06A)
    /// Cream initials on the book-of-the-month cover placeholder.
    static let cream = Color(hex: 0xF4E6CF)
    /// Card fill behind the book-of-the-month panel.
    static let cardFill = Color(hex: 0x2E2717)
    /// Rail accent for long-form ("Needs a Narrator") rows.
    static let railLong = Color(hex: 0x5A6A9A)
    /// Rail accent for short-form ("Short Works") rows.
    static let railShort = Color(hex: 0x6F5A9A)
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
