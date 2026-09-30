import Foundation

/// Hex values for the Voxglass palette in both appearances and Increase Contrast modes.
public enum PaletteSpec {
    public struct Pair: Sendable {
        public let standard: UInt32
        public let highContrast: UInt32
        public let light: UInt32
        public let lightHighContrast: UInt32

        public init(standard: UInt32, highContrast: UInt32, light: UInt32, lightHighContrast: UInt32) {
            self.standard = standard
            self.highContrast = highContrast
            self.light = light
            self.lightHighContrast = lightHighContrast
        }
    }

    public static let bg = Pair(standard: 0x0A0B0D, highContrast: 0x000000, light: 0xF7F4EF, lightHighContrast: 0xFFFFFF)
    public static let surface = Pair(standard: 0x17191D, highContrast: 0x101114, light: 0xFFFFFF, lightHighContrast: 0xF4F1EB)
    public static let raised = Pair(standard: 0x1B1D22, highContrast: 0x141519, light: 0xF0ECE5, lightHighContrast: 0xE5E0D8)
    public static let ink = Pair(standard: 0xF2F4F6, highContrast: 0xFFFFFF, light: 0x201B16, lightHighContrast: 0x000000)
    public static let ink2 = Pair(standard: 0xC4C7CC, highContrast: 0xE6E8EB, light: 0x5B554E, lightHighContrast: 0x302B26)
    public static let ink3 = Pair(standard: 0x8E9298, highContrast: 0xBFC3C8, light: 0x706A62, lightHighContrast: 0x4A443E)
    public static let brass = Pair(standard: 0xE3A44B, highContrast: 0xF2BE6E, light: 0x8A5A0A, lightHighContrast: 0x704600)
    public static let hairlineAlpha = (standard: 0.10, highContrast: 0.28)
    public static let surfaceLineAlpha = (standard: 0.08, highContrast: 0.24)

    /// WCAG 2.x relative luminance of an sRGB hex colour.
    public static func luminance(_ hex: UInt32) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red = linear(Double((hex >> 16) & 0xFF) / 255)
        let green = linear(Double((hex >> 8) & 0xFF) / 255)
        let blue = linear(Double(hex & 0xFF) / 255)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// WCAG 2.x contrast ratio between two opaque colours (at least 1).
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
