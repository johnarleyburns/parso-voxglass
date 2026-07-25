import Foundation
import CloudKit

public enum SyncGate {
    public static func shouldSync(
        iCloudSyncEnabled: Bool,
        accountStatus: CKAccountStatus
    ) -> Bool {
        iCloudSyncEnabled && accountStatus == .available
    }
}
