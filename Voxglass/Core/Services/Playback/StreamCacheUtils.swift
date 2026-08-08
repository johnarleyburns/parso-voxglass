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

    /// MIME type for ordinary audio URLs and historical cache blob names such
    /// as `sha256-mp3`. Those blob names intentionally preserve the existing
    /// cache identity, but they do not have a real filename extension, so
    /// AVFoundation needs an explicit format hint for direct local playback.
    public static func audioMIMEType(for url: URL) -> String? {
        let filename = url.lastPathComponent.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        let audioExtension = pathExtension.isEmpty
            ? filename.split(separator: "-").last.map(String.init) ?? ""
            : pathExtension

        switch audioExtension {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return nil
        }
    }
}
