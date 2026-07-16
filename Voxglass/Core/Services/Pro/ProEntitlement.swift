import Foundation
import StoreKit

public struct ProEntitlement: Equatable, Sendable {
    public let productID: String
    public let purchaseDate: Date

    private init(productID: String, purchaseDate: Date) {
        self.productID = productID
        self.purchaseDate = purchaseDate
    }

    public static func from(_ transaction: Transaction) -> ProEntitlement? {
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
