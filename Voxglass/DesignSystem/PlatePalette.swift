import SwiftUI
import VoxglassCore

enum PlatePalette {
    static func pair(for title: String, author: String?) -> (background: Color, ink: Color, index: Int) {
        let index = CoverPaletteIndex.index(title: title, author: author, count: PlatePaletteValues.pairs.count)
        let pair = PlatePaletteValues.pairs[index]
        return (Color(.sRGB, red: pair.background.red, green: pair.background.green, blue: pair.background.blue), Color(.sRGB, red: pair.ink.red, green: pair.ink.green, blue: pair.ink.blue), index)
    }
}
