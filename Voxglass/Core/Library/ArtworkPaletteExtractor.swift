import Foundation

/// The three colors extracted from a small RGBA artwork sample.
public struct ArtworkPalette: Equatable, Sendable, Codable {
    public let dominant: PlateRGB
    public let vivid: PlateRGB
    public let deep: PlateRGB

    public init(dominant: PlateRGB, vivid: PlateRGB, deep: PlateRGB) {
        self.dominant = dominant; self.vivid = vivid; self.deep = deep
    }
}

/// Deterministic, platform-free artwork palette extraction.
public enum ArtworkPaletteExtractor {
    public static func extract(rgba8: [UInt8], width: Int = 32, height: Int = 32) -> ArtworkPalette {
        guard width > 0, height > 0, rgba8.count >= width * height * 4 else {
            let black = PlateRGB(red: 0.04, green: 0.04, blue: 0.05)
            return ArtworkPalette(dominant: black, vivid: black, deep: black)
        }
        var points: [Lab] = []
        points.reserveCapacity(width * height)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            points.append(Lab(rgb: PlateRGB(red: Double(rgba8[i]) / 255, green: Double(rgba8[i + 1]) / 255, blue: Double(rgba8[i + 2]) / 255)))
        }
        let quadrants = [
            mean(points, xRange: 0..<(width / 2), yRange: 0..<(height / 2), width: width),
            mean(points, xRange: (width / 2)..<width, yRange: 0..<(height / 2), width: width),
            mean(points, xRange: 0..<(width / 2), yRange: (height / 2)..<height, width: width),
            mean(points, xRange: (width / 2)..<width, yRange: (height / 2)..<height, width: width)
        ]
        var centers = quadrants
        for _ in 0..<8 {
            var sums = Array(repeating: Lab.zero, count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)
            for point in points {
                let index = centers.indices.min(by: { distance(point, centers[$0]) < distance(point, centers[$1]) }) ?? 0
                sums[index] = sums[index] + point; counts[index] += 1
            }
            centers = centers.indices.map { counts[$0] == 0 ? centers[$0] : sums[$0] / Double(counts[$0]) }
        }
        let sizes = centers.map { center in points.reduce(into: 0) { if distance($1, center) < 22 { $0 += 1 } } }
        let dominantLab = centers[sizes.indices.max(by: { sizes[$0] < sizes[$1] }) ?? 0]
        let vividLab = centers.filter { (25...70).contains($0.l) }.max { chroma($0) < chroma($1) } ?? dominantLab
        let deepLab = Lab(l: dominantLab.l * 0.45, a: dominantLab.a, b: dominantLab.b)
        return ArtworkPalette(dominant: dominantLab.rgb, vivid: vividLab.rgb, deep: deepLab.rgb)
    }

    fileprivate struct Lab {
        var l: Double; var a: Double; var b: Double
        static let zero = Lab(l: 0, a: 0, b: 0)
        init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }
        init(rgb: PlateRGB) {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            let r = linear(rgb.red), g = linear(rgb.green), b = linear(rgb.blue)
            let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
            let y = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 1.0
            let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
            func pivot(_ value: Double) -> Double { value > 0.008856 ? pow(value, 1.0 / 3.0) : 7.787 * value + 16.0 / 116.0 }
            let fx = pivot(x), fy = pivot(y), fz = pivot(z)
            self.init(l: max(0, 116 * fy - 16), a: 500 * (fx - fy), b: 200 * (fy - fz))
        }
        var rgb: PlateRGB {
            func pivot(_ value: Double) -> Double { let cube = value * value * value; return cube > 0.008856 ? cube : (value - 16.0 / 116.0) / 7.787 }
            let fy = (l + 16) / 116, fx = a / 500 + fy, fz = fy - b / 200
            let x = 0.95047 * pivot(fx), y = pivot(fy), z = 1.08883 * pivot(fz)
            func gamma(_ value: Double) -> Double { let value = value.clamped(to: 0...1); return value > 0.0031308 ? 1.055 * pow(value, 1 / 2.4) - 0.055 : 12.92 * value }
            return PlateRGB(red: gamma(x * 3.2406 - y * 1.5372 - z * 0.4986), green: gamma(-x * 0.9689 + y * 1.8758 + z * 0.0415), blue: gamma(x * 0.0557 - y * 0.2040 + z * 1.0570))
        }
    }

    private static func mean(_ points: [Lab], xRange: Range<Int>, yRange: Range<Int>, width: Int) -> Lab {
        let selected = yRange.flatMap { y in xRange.map { points[y * width + $0] } }
        guard !selected.isEmpty else { return .zero }
        var total = Lab.zero
        for point in selected { total = total + point }
        return total / Double(selected.count)
    }
    private static func distance(_ lhs: Lab, _ rhs: Lab) -> Double { pow(lhs.l - rhs.l, 2) + pow(lhs.a - rhs.a, 2) + pow(lhs.b - rhs.b, 2) }
    private static func chroma(_ value: Lab) -> Double { hypot(value.a, value.b) }
}

fileprivate extension ArtworkPaletteExtractor.Lab {
    static func + (lhs: Self, rhs: Self) -> Self { .init(l: lhs.l + rhs.l, a: lhs.a + rhs.a, b: lhs.b + rhs.b) }
    static func / (lhs: Self, rhs: Double) -> Self { .init(l: lhs.l / rhs, a: lhs.a / rhs, b: lhs.b / rhs) }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
