import Foundation

public final class SyncMutationLog {
    private let stateStore: CloudSyncStateStore

    public init(stateStore: CloudSyncStateStore) {
        self.stateStore = stateStore
    }

    public func enqueue(localID: String, recordType: String, changeType: String = "update") async throws {
        try await stateStore.enqueuePending(localID: localID, recordType: recordType, changeType: changeType)
    }
}
