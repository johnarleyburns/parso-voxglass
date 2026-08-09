import Foundation
import VoxglassCore

/// Persisted working-cache limit for the production narration cache (§6.5,
/// D-5). The default is clamped at first run to about 15% of free space so a
/// small device never adopts a 10 GB cache it cannot afford; the user can then
/// raise it within the valid 2–100 GB range.
public struct ProductionCacheSettings: @unchecked Sendable {
    public static let workingCacheKey = "voxglass.production.workingCacheBytes"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The effective working-cache cap. First read applies the D-5 first-run
    /// clamp and persists it so later reads are stable.
    public var workingCacheBytes: Int64 {
        get {
            if let stored = defaults.object(forKey: Self.workingCacheKey) as? NSNumber {
                return stored.int64Value
            }
            let free = FreeSpaceProvider.availableBytes ?? 0
            let clamped = ProductionCacheLimits.firstRunWorkingCache(freeBytes: free)
            defaults.set(NSNumber(value: clamped), forKey: Self.workingCacheKey)
            return clamped
        }
        set {
            defaults.set(NSNumber(value: newValue), forKey: Self.workingCacheKey)
        }
    }

    /// Reads without mutating defaults (used by tests and read-only surfaces).
    public static func storedWorkingCacheBytes(defaults: UserDefaults = .standard) -> Int64? {
        (defaults.object(forKey: workingCacheKey) as? NSNumber)?.int64Value
    }
}
