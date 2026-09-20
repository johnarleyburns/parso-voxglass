import Foundation
import ParsoAudioStreaming

/// Composition root for the streaming/offline audio cache. The store itself is
/// `ParsoAudioStreaming.SparseCacheStore` (shared with parso-tonearm, see
/// `parso-audio-engine/docs/UNIFICATION_PLAN.md` Phase 2); this enum owns the one
/// process-wide instance, Voxglass's cache-key identity, the custom URL scheme,
/// and the user-facing size presets.
///
/// Two roots (INV-A): streaming blobs are purgeable under Caches; pinned offline
/// downloads live under Application Support where the OS never reclaims them.
public enum AudioCache {

    public struct StorageUsage: Equatable, Sendable {
        public let streamingBytes: Int64
        public let durableBytes: Int64
        public let streamingAudioCount: Int
        public let durableAudioCount: Int

        public var totalBytes: Int64 { streamingBytes + durableBytes }
        public var totalAudioCount: Int { streamingAudioCount + durableAudioCount }

        public init(
            streamingBytes: Int64,
            durableBytes: Int64,
            streamingAudioCount: Int,
            durableAudioCount: Int
        ) {
            self.streamingBytes = streamingBytes
            self.durableBytes = durableBytes
            self.streamingAudioCount = streamingAudioCount
            self.durableAudioCount = durableAudioCount
        }
    }

    /// Custom scheme the resource loader answers for; rewritten from http(s).
    public static let scheme = "voxglass-cache"

    /// Voxglass keeps the historical key shape: `<sha256hex>` with a `-<ext>`
    /// suffix only when the URL has a filename extension.
    public static let keyStrategy: CacheKeyStrategy = .sha256WithOptionalExtension

    public static func key(for url: URL) -> String { keyStrategy.key(url) }

    static let evictableRoot: URL = {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Voxglass/StreamCacheV2", isDirectory: true)
    }()

    static let durableRoot: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Voxglass/OfflineStoreV2", isDirectory: true)
    }()

    /// The one process-wide store. Its limit is seeded from the saved preset.
    public static let shared = SparseCacheStore(
        evictableRoot: evictableRoot,
        durableRoot: durableRoot,
        limitBytes: CachePreset.selected.rawValue)

    /// Synchronous, actor-free view of the same on-disk layout (SwiftUI artwork
    /// lookups, phone→watch transfer path).
    public static let layout = SparseCacheLayout(evictableRoot: evictableRoot, durableRoot: durableRoot)

    // MARK: - Size presets (Settings UI)

    public enum CachePreset: Int64, CaseIterable, Sendable {
        case m500MB = 524_288_000
        case g2GB = 2_147_483_648
        case g10GB = 10_737_418_240

        public var displayName: String {
            switch self {
            case .m500MB: return "500 MB"
            case .g2GB: return "2 GB"
            case .g10GB: return "10 GB"
            }
        }

        public var accessibilitySuffix: String {
            switch self {
            case .m500MB: return "500mb"
            case .g2GB: return "2gb"
            case .g10GB: return "10gb"
            }
        }

        private static let defaultsKey = "voxglass.cachePreset"

        public static var selected: CachePreset {
            let raw = UserDefaults.standard.integer(forKey: defaultsKey)
            return CachePreset(rawValue: Int64(raw)) ?? .m500MB
        }

        /// Persists the choice and re-applies the budget to the live store.
        public static func select(_ preset: CachePreset) async {
            UserDefaults.standard.set(Int(preset.rawValue), forKey: defaultsKey)
            await shared.setLimit(preset.rawValue)
        }
    }

    // MARK: - Maintenance (bootstrap + Settings)

    public static func evictToCurrentBudget() async {
        await shared.setLimit(CachePreset.selected.rawValue)
    }

    public static func storageUsage() async -> StorageUsage {
        StorageUsage(
            streamingBytes: await shared.totalCachedBytes(),
            durableBytes: await shared.totalDurableBytes(),
            streamingAudioCount: await shared.completeEntryCount(kind: "audio", durable: false),
            durableAudioCount: await shared.completeEntryCount(kind: "audio", durable: true)
        )
    }

    /// Clears only the evictable streaming tier. The in-memory artwork tier is
    /// cleared separately by the caller (`ArtworkService.clearMemory()`).
    public static func clearStreamingCache() async {
        await shared.clearEvictable()
    }

    /// Clears only pinned/offline files. Download records are owned by
    /// `OfflineDownloadManager` and are cleared by that manager before this is
    /// called from the Settings screen.
    public static func clearOfflineCache() async {
        await shared.clearDurable()
    }

    /// Clears both streaming and pinned/offline files.
    ///
    /// This only touches the two cache roots. It never deletes the library
    /// database or user-selected local-book files, which remain at their
    /// original URLs outside the cache.
    public static func clearCache() async {
        await shared.clearAll()
    }
}

public extension SparseCacheStore {
    /// Pin/unpin a batch for offline use — moves each blob between the streaming
    /// and durable roots. A thin loop over the library's `setDurable(_:for:)`.
    func pin(_ keys: [String]) { for key in keys { setDurable(true, for: key) } }
    func unpin(_ keys: [String]) { for key in keys { setDurable(false, for: key) } }
}
