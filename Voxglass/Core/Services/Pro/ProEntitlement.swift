import Foundation
import StoreKit

struct ProEntitlement: Equatable, Sendable {
    let productID: String
    let purchaseDate: Date
    let environment: StoreKit.Environment

    private init(productID: String, purchaseDate: Date, environment: StoreKit.Environment) {
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.environment = environment
    }

    static func from(_ transaction: Transaction) -> ProEntitlement? {
        guard transaction.productType == .nonConsumable,
              transaction.revocationDate == nil,
              let expirationDate = transaction.expirationDate,
              expirationDate > Date() || transaction.expirationDate == nil else {
            return nil
        }
        return ProEntitlement(
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            environment: transaction.environment
        )
    }
}
