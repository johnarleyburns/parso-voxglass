import Foundation
import StoreKit
import VoxglassCore

/// StoreKit 2 implementation of the Pro license seam (§13.5). Lives in the app
/// target because Core stays StoreKit-free — exactly the way CloudKit lives
/// behind `ProductionSyncTransport`. Tests use `StaticLicenseProvider`.
///
/// Non-consumable, one-time purchase. Restore Purchases is always available.
/// The verified purchase is cached in `EntitlementCache` so a Pro user never
/// sees a locked UI while StoreKit warms up; the cache stands indefinitely
/// offline (§17.4). A refund or revocation returns the app to free while
/// preserving every project and file.
public final class StoreKitLicenseProvider: LicenseProvider, @unchecked Sendable {

    private let cache: EntitlementCache
    private let updatesContinuation: AsyncStream<EntitlementState>.Continuation
    private let updatesTask: Task<Void, Never>

    public let updates: AsyncStream<EntitlementState>

    public init(cache: EntitlementCache = EntitlementCache()) {
        self.cache = cache
        var continuation: AsyncStream<EntitlementState>.Continuation!
        let stream = AsyncStream<EntitlementState> { continuation = $0 }
        self.updatesContinuation = continuation
        self.updates = stream
        let capturedContinuation: AsyncStream<EntitlementState>.Continuation = continuation
        // Transaction.updates surfaces revocations, refunds, and purchases made
        // on another device. A revocation reverts to free — the cache is cleared
        // but no file is touched (§18 IAP).
        self.updatesTask = Task { [cache, capturedContinuation] in
            for await result in Transaction.updates {
                guard let transaction = try? result.payloadValue else { continue }
                await transaction.finish()
                guard transaction.productID == NarrationProProduct.productID else { continue }
                if transaction.revocationDate != nil {
                    cache.clear()
                    capturedContinuation.yield(.free)
                } else {
                    cache.store(.pro(since: transaction.purchaseDate))
                    cache.storeTransactionID(transaction.originalID)
                    capturedContinuation.yield(.pro(since: transaction.purchaseDate))
                }
            }
        }
    }

    deinit {
        updatesTask.cancel()
    }

    // MARK: - LicenseProvider

    public var entitlement: EntitlementState {
        get async {
            var sawUnverified = false
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    if transaction.productID == NarrationProProduct.productID {
                        cache.store(.pro(since: transaction.purchaseDate))
                        cache.storeTransactionID(transaction.originalID)
                        return .pro(since: transaction.purchaseDate)
                    }
                case .unverified:
                    // Verification could not complete (offline). Keep the cached
                    // value: the cache never expires, so a narrator on a plane
                    // with a deadline does not lose their exporter (§17.4).
                    sawUnverified = true
                }
            }
            if sawUnverified {
                return cache.load()
            }
            // No valid current entitlement: refunded, revoked, or never bought.
            // Revert to free; no data is deleted.
            if case .pro = cache.load() {
                cache.clear()
            }
            return .free
        }
    }

    public func refresh() async {
        _ = await entitlement
    }

    public func purchasePro() async throws -> EntitlementState {
        let products = try await Product.products(for: [NarrationProProduct.productID])
        guard let product = products.first else { throw LicenseError.notAvailable }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try Self.verified(verification)
            await transaction.finish()
            cache.store(.pro(since: transaction.purchaseDate))
            cache.storeTransactionID(transaction.originalID)
            return .pro(since: transaction.purchaseDate)
        case .userCancelled:
            throw LicenseError.cancelled
        case .pending:
            // Ask to Buy / approval pending — never treated as Pro until verified.
            return .pending
        @unknown default:
            throw LicenseError.purchaseFailed("Unknown purchase result.")
        }
    }

    public func restore() async throws -> EntitlementState {
        // StoreKit 2 restores non-consumables automatically; sync with the store
        // to refresh the current entitlements, then report what we now hold.
        do {
            try await AppStore.sync()
        } catch {
            // A failed sync still reports the locally-known entitlement.
        }
        return await entitlement
    }

    public func product() async throws -> ProductInfo {
        let products = try await Product.products(for: [NarrationProProduct.productID])
        guard let product = products.first else { throw LicenseError.notAvailable }
        return ProductInfo(
            displayPrice: product.displayPrice,
            displayName: product.displayName,
            description: product.description
        )
    }

    // MARK: - Helpers

    private static func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw LicenseError.unverified
        }
    }
}
