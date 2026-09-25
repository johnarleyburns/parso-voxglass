import Foundation

/// An sRGB color used by deterministic typographic cover plates.
public struct PlateRGB: Equatable, Sendable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The stable eight-color palette shared by Core tests and the SwiftUI plate.
public enum PlatePaletteValues {
    public static let pairs: [(background: PlateRGB, ink: PlateRGB)] = [
        (.init(red: 0x5B / 255.0, green: 0x1F / 255.0, blue: 0x24 / 255.0), .init(red: 0xF3 / 255.0, green: 0xD9 / 255.0, blue: 0xC7 / 255.0)),
        (.init(red: 0x1F / 255.0, green: 0x3A / 255.0, blue: 0x2C / 255.0), .init(red: 0xE8 / 255.0, green: 0xDD / 255.0, blue: 0xBF / 255.0)),
        (.init(red: 0x1C / 255.0, green: 0x2B / 255.0, blue: 0x4A / 255.0), .init(red: 0xE6 / 255.0, green: 0xD7 / 255.0, blue: 0xB0 / 255.0)),
        (.init(red: 0x6E / 255.0, green: 0x4A / 255.0, blue: 0x17 / 255.0), .init(red: 0xFB / 255.0, green: 0xEB / 255.0, blue: 0xC8 / 255.0)),
        (.init(red: 0x2E / 255.0, green: 0x34 / 255.0, blue: 0x40 / 255.0), .init(red: 0xE3 / 255.0, green: 0xA4 / 255.0, blue: 0x4B / 255.0)),
        (.init(red: 0x3E / 255.0, green: 0x23 / 255.0, blue: 0x40 / 255.0), .init(red: 0xEB / 255.0, green: 0xD3 / 255.0, blue: 0xDF / 255.0)),
        (.init(red: 0x16 / 255.0, green: 0x40 / 255.0, blue: 0x3F / 255.0), .init(red: 0xD8 / 255.0, green: 0xEA / 255.0, blue: 0xD9 / 255.0)),
        (.init(red: 0x7A / 255.0, green: 0x3B / 255.0, blue: 0x1C / 255.0), .init(red: 0xF6 / 255.0, green: 0xE0 / 255.0, blue: 0xC8 / 255.0))
    ]
}
