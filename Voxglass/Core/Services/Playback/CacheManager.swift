import Foundation

public actor CacheManager {
    public static let shared = CacheManager()

    public enum CachePreset: Int64, CaseIterable {
        case free500MB = 524_288_000
        case pro2GB = 2_147_483_648
        case pro10GB = 10_737_418_240

        public var displayName: String {
            switch self {
            case .free500MB: return "500 MB"
            case .pro2GB: return "2 GB"
            case .pro10GB: return "10 GB"
            }
        }

        public var isProOnly: Bool {
            switch self {
            case .free500MB: return false
            case .pro2GB, .pro10GB: return true
            }
        }

        public var accessibilitySuffix: String {
            switch self {
            case .free500MB: return "500mb"
            case .pro2GB: return "2gb"
            case .pro10GB: return "10gb"
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
                if preset.isProOnly, !ProFeature.isEnabled(.cachePresets) {
                    return .free500MB
                }
                return preset
            }
            return .free500MB
        }
    }

    public func setPreset(_ preset: CachePreset) async {
        guard !preset.isProOnly || ProFeature.isEnabled(.cachePresets) else { return }
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

