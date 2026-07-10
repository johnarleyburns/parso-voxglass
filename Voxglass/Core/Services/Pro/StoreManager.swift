import Combine
import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var isPro = false
    @Published private(set) var isRestoring = false
    @Published private(set) var products: [Product] = []
    @Published var purchaseError: String?

    private let productIDs = ["guru.parso.voxglass.pro"]
    private var updatesTask: Task<Void, Never>?

    private init() {
        isPro = EntitlementCache.shared.isEntitled
        updatesTask = Task {
            await observeTransactionUpdates()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: productIDs)
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                if let entitlement = await verifyAndCache(verification) {
                    isPro = true
                    EntitlementCache.shared.cacheEntitlement(true, productID: entitlement.productID)
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlement() async {
        var foundEntitlement = false

        for await verification in Transaction.currentEntitlements {
            switch verification {
            case .verified(let transaction):
                if let entitlement = ProEntitlement.from(transaction) {
                    foundEntitlement = true
                    EntitlementCache.shared.cacheEntitlement(true, productID: entitlement.productID)
                }
            case .unverified:
                break
            }
            if foundEntitlement { break }
        }

        if !foundEntitlement {
            EntitlementCache.shared.cacheEntitlement(false)
        }
        isPro = EntitlementCache.shared.isEntitled
    }

    private func verifyAndCache(_ verification: VerificationResult<Transaction>) async -> ProEntitlement? {
        switch verification {
        case .verified(let transaction):
            if let entitlement = ProEntitlement.from(transaction) {
                await transaction.finish()
                return entitlement
            }
            return nil
        case .unverified:
            return nil
        }
    }

    private func observeTransactionUpdates() async {
        for await verification in Transaction.updates {
            if let entitlement = await verifyAndCache(verification) {
                isPro = true
                EntitlementCache.shared.cacheEntitlement(true, productID: entitlement.productID)
            } else {
                await refreshEntitlement()
            }
        }
    }
}
