import Foundation

enum ProFeature: String, CaseIterable {
    case cachePresets
    case prefetchDepth
    case folderWatch
    case eq
    case carplay
    case icloudSync
    case listeningStats
    case appleWatch
    case offlineDownloads

    static func isEnabled(_ feature: ProFeature) -> Bool {
        EntitlementCache.shared.isEntitled
    }
}

final class EntitlementCache: @unchecked Sendable {
    static let shared = EntitlementCache()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private let entitlementKey = "voxglass.pro.entitlement"
    private let productIDKey = "voxglass.pro.productID"

    private(set) var isEntitled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isEntitled }
        set { lock.lock(); _isEntitled = newValue; lock.unlock() }
    }
    private var _isEntitled: Bool

    private init() {
        _isEntitled = Self.loadCached(defaults: defaults, entitlementKey: entitlementKey)
    }

    func cacheEntitlement(_ entitled: Bool, productID: String? = nil) {
        isEntitled = entitled
        defaults.set(entitled, forKey: entitlementKey)
        if let pid = productID {
            defaults.set(pid, forKey: productIDKey)
        }
    }

    var cachedProductID: String? {
        defaults.string(forKey: productIDKey)
    }

    private static func loadCached(defaults: UserDefaults, entitlementKey: String) -> Bool {
        defaults.bool(forKey: entitlementKey)
    }
}
