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
        let digest = SHA256.hash(data: Data(canonicalURLString(for: url).utf8))
        return "art_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func fileName(for url: URL) -> String { key(for: url) }

    /// Catalog and library records can use different IA cover URL variants
    /// (different hosts, query parameters, or an image file under /download),
    /// while still referring to the same work. Keep one cache entry for them.
    public static func canonicalURLString(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.removingPercentEncoding ?? url.path
        if host.hasSuffix("archive.org") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].lowercased() == "services", parts[1].lowercased() == "img" {
                return "ia:\(parts.dropFirst(2).joined(separator: "/").lowercased())"
            }
            if parts.count >= 2, parts[0].lowercased() == "download" {
                return "ia:\(parts[1].lowercased())"
            }
        }

        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = host
        components.port = url.port
        components.path = path
        return components.string ?? url.absoluteString
    }
}
