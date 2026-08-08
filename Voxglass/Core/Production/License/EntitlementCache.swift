import Foundation

/// Persists the last verified `.pro(since:)` entitlement in the app's
/// preferences (§17.4).
///
/// Contract:
/// - On launch the cached value is used **immediately** so a Pro user never
///   sees a locked UI while StoreKit warms up; it is then confirmed
///   asynchronously by the provider.
/// - If confirmation says `.free` (refund/revocation) the app reverts and
///   shows a one-time notice. No data is deleted.
/// - If confirmation cannot complete (offline) the cached value stands
///   **indefinitely** — the cache never expires, so a narrator on a plane with
///   a deadline does not lose their exporter.
public struct EntitlementCache: Sendable {
    public static let proSinceKey = "voxglass.narration.pro.since"
    public static let transactionIDKey = "voxglass.narration.pro.transaction"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last verified pro purchase, or `.free` when nothing is cached.
    public func load() -> EntitlementState {
        let since = defaults.double(forKey: Self.proSinceKey)
        guard since > 0 else { return .free }
        return .pro(since: Date(timeIntervalSinceReferenceDate: since))
    }

    /// Persists a verified pro entitlement. Free/pending/unknown states are
    /// never written here — the cache only ever records a confirmed purchase.
    public func store(_ state: EntitlementState) {
        switch state {
        case .pro(let since):
            defaults.set(since.timeIntervalSinceReferenceDate, forKey: Self.proSinceKey)
        case .free, .pending, .unknown:
            break
        }
    }

    /// Records the transaction ID of the verified purchase (for diagnostics).
    public func storeTransactionID(_ id: UInt64) {
        defaults.set(String(id), forKey: Self.transactionIDKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.proSinceKey)
        defaults.removeObject(forKey: Self.transactionIDKey)
    }
}
