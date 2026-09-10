import Foundation
import StoreKit
import VoxglassCore

/// A purely optional, non-gating one-time consumable — "Contribute to
/// Development". Nothing in the app checks this before unlocking a
/// feature; the only effect of a successful purchase is flipping the
/// persisted supporter flag so a small badge can show on the home view.
/// Because it's a consumable, StoreKit itself won't "restore" it on a new
/// device — the badge is a thank-you for this device's purchase, not a
/// re-verified entitlement, so that's fine.
@MainActor
final class SupportDevelopmentStore {
    static let shared = SupportDevelopmentStore()

    static let productID = "guru.parso.voxglass.support.dev"
    static let displayName = "Contribute to Development"

    private(set) var product: Product?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result, transaction.productID == Self.productID {
                    await self.markSupporter()
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProduct() async throws -> Product {
        if let product { return product }
        let products = try await Product.products(for: [Self.productID])
        guard let product = products.first else {
            throw SupportDevelopmentError.notAvailable
        }
        self.product = product
        return product
    }

    @discardableResult
    func purchase() async throws -> Bool {
        let product = try await loadProduct()
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw SupportDevelopmentError.unverified
            }
            markSupporter()
            await transaction.finish()
            return true
        case .userCancelled:
            return false
        case .pending:
            return false
        @unknown default:
            return false
        }
    }

    private func markSupporter() {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.isSupporter)
    }
}

enum SupportDevelopmentError: Error {
    case notAvailable
    case unverified
}
