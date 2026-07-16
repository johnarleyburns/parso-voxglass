import CryptoKit
import Foundation

/// Validates that a cover-art URL resolves to a real (non-placeholder) image.
/// Cover resolution lives in Core, but image *decoding* needs UIKit, so the
/// concrete check is provided by the app-side `ArtworkService`; Core depends only
/// on this seam. On the host (`swift test`) a stub can be injected.
public protocol CoverArtworkValidating: Sendable {
    func imageValidates(at url: URL) async -> Bool
}

/// Stable, deterministic cache keys for cover artwork. Lives in Core so the
/// library layer and the app-side `ArtworkService` derive identical keys.
public enum ArtworkCacheKey {
    /// The `art_` prefix avoids collisions with audio cache keys produced by
    /// `CachingResourceLoader.key(for:)`.
    public static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "art_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func fileName(for url: URL) -> String { key(for: url) }
}
