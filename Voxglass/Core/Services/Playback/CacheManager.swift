import Foundation

actor CacheManager {
    static let shared = CacheManager()

    enum CachePreset: Int64, CaseIterable {
        case free500MB = 524_288_000
        case pro2GB = 2_147_483_648
        case pro10GB = 10_737_418_240

        var displayName: String {
            switch self {
            case .free500MB: return "500 MB"
            case .pro2GB: return "2 GB"
            case .pro10GB: return "10 GB"
            }
        }

        var isProOnly: Bool {
            switch self {
            case .free500MB: return false
            case .pro2GB, .pro10GB: return true
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let presetKey = "voxglass.cachePreset"

    var currentBudget: Int64 {
        selectedPreset.rawValue
    }

    var selectedPreset: CachePreset {
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

    func setPreset(_ preset: CachePreset) async {
        guard !preset.isProOnly || ProFeature.isEnabled(.cachePresets) else { return }
        defaults.set(Int(preset.rawValue), forKey: presetKey)
        await StreamCacheStore.shared.setLimit(preset.rawValue)
    }

    func currentCacheBytes() async -> Int64 {
        await StreamCacheStore.shared.totalCachedBytes()
    }

    func evictIfNeeded() async {
        await StreamCacheStore.shared.setLimit(currentBudget)
    }

    func clearCache() async {
        await StreamCacheStore.shared.clearAll()
        ArtworkService.shared.clearMemory()
    }

    func garbageCollectStalePartials() async {
        await StreamCacheStore.shared.garbageCollectStalePartials()
    }
}

