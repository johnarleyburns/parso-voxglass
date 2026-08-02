import Foundation
import StoreKit
import VoxglassCore

/// The real `LicenseProvider` backed by StoreKit 2 (§17.2). Lives in the
/// Studio target; unit tests use `FakeLicenseProvider` so `swift test` never
/// touches the StoreKit sandbox.
///
/// StoreKit contract honored here:
/// - The `Transaction.updates` listener is started in `init` **before** any
///   other StoreKit call, and every transaction received is finished.
/// - `entitlement` is seeded from `EntitlementCache` (§17.4) so a Pro user
///   never sees a locked UI while StoreKit warms up; `refresh()` confirms
///   against `Transaction.currentEntitlements` and updates the cache.
/// - Unverified results map to `.unknown`, never `.pro`.
public final class StoreKitLicenseProvider: LicenseProvider, @unchecked Sendable {
    public static let productID = "guru.parso.voxglass.studio.pro"

    private let lock = NSLock()
    private var state: EntitlementState
    private let cache: EntitlementCache
    private let continuation: AsyncStream<EntitlementState>.Continuation
    public let updates: AsyncStream<EntitlementState>

    public init(
        productID: String = StoreKitLicenseProvider.productID,
        cache: EntitlementCache = EntitlementCache()
    ) {
        self.cache = cache
        self.state = cache.load()
        var c: AsyncStream<EntitlementState>.Continuation!
        let stream = AsyncStream<EntitlementState> { c = $0 }
        self.continuation = c
        self.updates = stream

        // §17.2 — the updates listener must start before any other StoreKit
        // call. The task is detached from the init's caller and outlives it.
        Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                if let transaction = try? result.payloadValue {
                    if transaction.productID == productID {
                        await transaction.finish()
                    }
                }
                await self.refresh()
            }
        }
    }

    // MARK: - LicenseProvider

    public var entitlement: EntitlementState {
        get async {
            readState()
        }
    }

    public func refresh() async {
        var current: EntitlementState = .free
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? result.payloadValue,
                  transaction.productID == Self.productID else { continue }
            switch result {
            case .verified(let t):
                current = .pro(since: t.originalPurchaseDate)
                cache.storeTransactionID(t.id)
            case .unverified:
                current = .unknown
            }
        }
        setState(current)
        cache.store(current)
        continuation.yield(current)
    }

    public func purchasePro() async throws -> EntitlementState {
        let products = try await Product.products(for: [Self.productID])
        guard let product = products.first else {
            throw LicenseError.notAvailable
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
            case .unverified:
                throw LicenseError.unverified
            }
            await refresh()
            return await entitlement
        case .userCancelled:
            throw LicenseError.cancelled
        case .pending:
            setState(.pending)
            continuation.yield(.pending)
            return .pending
        @unknown default:
            throw LicenseError.purchaseFailed("Unknown StoreKit purchase result")
        }
    }

    public func restore() async throws -> EntitlementState {
        try await AppStore.sync()
        await refresh()
        return await entitlement
    }

    public func product() async throws -> ProductInfo {
        let products = try await Product.products(for: [Self.productID])
        guard let product = products.first else {
            throw LicenseError.notAvailable
        }
        return ProductInfo(
            displayPrice: product.displayPrice,
            displayName: product.displayName,
            description: product.description
        )
    }

    // MARK: - Synchronized state

    private func readState() -> EntitlementState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func setState(_ newState: EntitlementState) {
        lock.lock()
        state = newState
        lock.unlock()
    }
}
