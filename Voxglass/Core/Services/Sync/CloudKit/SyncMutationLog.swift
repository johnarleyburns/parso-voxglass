import Foundation

/// The underlying state store is actor-isolated, so this reference is safe at
/// the database service boundary.
public final class SyncMutationLog: @unchecked Sendable {
    private let stateStore: CloudSyncStateStore

    public init(stateStore: CloudSyncStateStore) {
        self.stateStore = stateStore
    }

    public func enqueue(localID: String, recordType: String, changeType: String = "update") async throws {
        try await stateStore.enqueuePending(localID: localID, recordType: recordType, changeType: changeType)
    }
}
