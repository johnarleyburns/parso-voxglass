import Foundation

public actor CacheManager {
    public static let shared = CacheManager()

    public enum CachePreset: Int64, CaseIterable {
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
    }

    private let defaults = UserDefaults.standard
    private let presetKey = "voxglass.cachePreset"

    public var currentBudget: Int64 {
        selectedPreset.rawValue
    }

    public var selectedPreset: CachePreset {
        get {
            let raw = defaults.integer(forKey: presetKey)
            if let preset = CachePreset(rawValue: Int64(raw)) {
                return preset
            }
            return .m500MB
        }
    }

    public func setPreset(_ preset: CachePreset) async {
        defaults.set(Int(preset.rawValue), forKey: presetKey)
        await StreamCacheStore.shared.setLimit(preset.rawValue)
    }

    public func currentCacheBytes() async -> Int64 {
        await StreamCacheStore.shared.totalCachedBytes()
    }

    public func evictIfNeeded() async {
        await StreamCacheStore.shared.setLimit(currentBudget)
    }

    /// Clears the on-disk stream cache. The in-memory artwork tier is cleared
    /// separately by the app-side caller (see `ArtworkService.clearMemory()`),
    /// since artwork rendering — and its cache — is an app/UIKit concern.
    public func clearCache() async {
        await StreamCacheStore.shared.clearAll()
    }

    public func garbageCollectStalePartials() async {
        await StreamCacheStore.shared.garbageCollectStalePartials()
    }
}

