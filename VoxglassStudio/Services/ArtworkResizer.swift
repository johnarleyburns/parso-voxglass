import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A decoded cover's pixel dimensions — used to validate against the
/// destination's `ArtworkRule` without holding the full bitmap.
public struct ArtworkPreview: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Decodes only the image header to read dimensions.
    public static func preview(data: Data) -> ArtworkPreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return ArtworkPreview(pixelWidth: width, pixelHeight: height)
    }
}

/// Image-framework-free (in Core) 2400 px derivative generation for the Studio
/// (spec §18.1.12, F-28): `ArtworkStore` declares the `cover2400` role but
/// nothing produced it. This uses ImageIO on the Studio target only — Core
/// stays image-framework-free.
enum ArtworkResizer {

    /// Downscales a JPEG/PNG to a square 2400×2400 JPEG (letterboxing is not
    /// applied — the destination artwork rule demands square covers, so a
    /// non-square source is reported, not silently padded). Returns nil when
    /// the source cannot be decoded.
    static func resizeTo2400(data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let edge = max(image.width, image.height)
        let scale = edge > 2400 ? Double(2400) / Double(edge) : 1.0
        let targetWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
