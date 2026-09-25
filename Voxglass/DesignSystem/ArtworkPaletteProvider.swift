import SwiftUI
import UIKit
import VoxglassCore

/// Loads and caches artwork palettes for content surfaces.
@MainActor
final class ArtworkPaletteProvider {
    static let shared = ArtworkPaletteProvider()
    private var cache: [URL: ArtworkPalette] = [:]

    func palette(for image: UIImage, url: URL? = nil) -> ArtworkPalette {
        if let url, let cached = cache[url] { return cached }
        let sample = image.resizedRGBA8(width: 32, height: 32)
        let palette = ArtworkPaletteExtractor.extract(rgba8: sample, width: 32, height: 32)
        if let url { cache[url] = palette }
        return palette
    }

    func clear() { cache.removeAll() }
}

private extension UIImage {
    func resizedRGBA8(width: Int, height: Int) -> [UInt8] {
        guard let cgImage else { return [] }
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
