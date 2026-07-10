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

    func setPreset(_ preset: CachePreset) {
        guard !preset.isProOnly || ProFeature.isEnabled(.cachePresets) else { return }
        defaults.set(Int(preset.rawValue), forKey: presetKey)

        if currentCacheBytes() > preset.rawValue {
            Task.detached(priority: .utility) {
                await self.evictToBudget(preset.rawValue)
            }
        }
    }

    func currentCacheBytes() -> Int64 {
        OpusCacheService.shared.cacheBytes()
    }

    func evictIfNeeded() async {
        let budget = currentBudget
        let used = currentCacheBytes()
        if used > budget {
            await evictToBudget(budget)
        }
    }

    private func evictToBudget(_ budget: Int64) async {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let opusDir = caches.appendingPathComponent("OpusCache", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: opusDir,
            includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, accessDate: Date, size: Int64)] = []
        var total: Int64 = 0

        for case let url as URL in enumerator {
            guard let resourceValues = try? url.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey]),
                  let accessDate = resourceValues.contentAccessDate,
                  let size = resourceValues.fileSize else { continue }
            files.append((url, accessDate, Int64(size)))
            total += Int64(size)
        }

        files.sort { $0.accessDate < $1.accessDate }

        var removed: Int64 = 0
        for file in files {
            guard total - removed > budget else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                removed += file.size
            } catch {
                // Continue with next file
            }
        }
    }

    func accountCAF(at url: URL) {
        // Update the access date so it doesn't get evicted immediately
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}
