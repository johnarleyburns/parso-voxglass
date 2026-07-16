import Foundation

public enum ProFeature: String, CaseIterable, Sendable {
    case cachePresets
    case prefetchDepth
    case folderWatch
    case eq
    case icloudSync
    case listeningStats
    case offlineDownloads
    case libraryBackup

    public static func isEnabled(_ feature: ProFeature) -> Bool {
        EntitlementCache.shared.isEntitled
    }
}

public final class EntitlementCache: @unchecked Sendable {
    public static let shared = EntitlementCache()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private let entitlementKey = "voxglass.pro.entitlement"
    private let productIDKey = "voxglass.pro.productID"

    #if DEBUG
    private var testOverride: Bool?
    #endif

    public private(set) var isEntitled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            #if DEBUG
            if let testOverride { return testOverride }
            #endif
            return _isEntitled
        }
        set { lock.lock(); _isEntitled = newValue; lock.unlock() }
    }
    private var _isEntitled: Bool

    private init() {
        _isEntitled = Self.loadCached(defaults: defaults, entitlementKey: entitlementKey)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-VoxglassForcePro") {
            testOverride = true
        } else if arguments.contains("-VoxglassForceFreeTier") {
            testOverride = false
        }
        #endif
    }

    #if DEBUG
    /// Test seam: forces entitlement on/off deterministically without StoreKit.
    /// Pass `nil` to fall back to the cached/real value.
    public func setTestEntitlement(_ value: Bool?) {
        lock.lock(); testOverride = value; lock.unlock()
    }
    #endif

    public func cacheEntitlement(_ entitled: Bool, productID: String? = nil) {
        isEntitled = entitled
        defaults.set(entitled, forKey: entitlementKey)
        if let pid = productID {
            defaults.set(pid, forKey: productIDKey)
        }
    }

    public var cachedProductID: String? {
        defaults.string(forKey: productIDKey)
    }

    private static func loadCached(defaults: UserDefaults, entitlementKey: String) -> Bool {
        defaults.bool(forKey: entitlementKey)
    }
}
