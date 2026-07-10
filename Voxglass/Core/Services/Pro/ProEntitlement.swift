import Foundation
import StoreKit

struct ProEntitlement: Equatable, Sendable {
    let productID: String
    let purchaseDate: Date

    private init(productID: String, purchaseDate: Date) {
        self.productID = productID
        self.purchaseDate = purchaseDate
    }

    static func from(_ transaction: Transaction) -> ProEntitlement? {
        guard transaction.productType == .nonConsumable,
              transaction.revocationDate == nil else {
            return nil
        }
        return ProEntitlement(
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate
        )
    }
}
