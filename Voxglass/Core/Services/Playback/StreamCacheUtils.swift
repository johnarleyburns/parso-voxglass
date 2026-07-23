import Foundation
import CryptoKit

/// Static utilities that work on both iOS and watchOS.
public enum StreamCacheUtils {
    public static let scheme = "voxglass-cache"

    /// Stable cache key for `url`, derived from a SHA256 of its absolute string.
    public static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hex : hex + "-" + ext
    }

    /// Returns true if this URL scheme should be routed through the cache.
    public static func isRemoteCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func cacheURL(for remote: URL) -> URL {
        var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        comps.scheme = scheme
        return comps.url ?? remote
    }
}
