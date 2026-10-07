#if os(iOS) || os(macOS)
import CloudKit
import CryptoKit
import Foundation
import VoxglassCore
import os

/// CKSyncEngine transport for the portable authoring-v2 entity envelope.
/// The legacy Library and VGProductionStudioZone transports remain independent.
public actor CloudKitAuthoringV2Sync: CKSyncEngineDelegate {
    public static let containerIdentifier = "iCloud.guru.parso.voxglass"
    public static let zoneName = AuthoringProtocol.zoneName
    public static let recordType = "VGAuthoringEntityV2"

    private let container: CKContainer
    private let database: CKDatabase
    private let baseDatabaseURL: URL
    private var store: AuthoringLocalStore?
    private var accountScope: String?
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitAuthoringV2Sync.zoneName, ownerName: CKCurrentUserDefaultName)
    private var engine: CKSyncEngine?
    private var fetchInProgress = false
    private var deferredState: CKSyncEngine.State.Serialization?
    private var fetchApplyFailed = false
    private var checkpointBlocked = false
    private var pausedForAccountSwitch = false
    public private(set) var lastFailure: AuthoringCloudKitFailure?

    public init(databaseURL: URL, containerIdentifier: String = CloudKitAuthoringV2Sync.containerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.baseDatabaseURL = databaseURL
    }

    /// Starts or restores CKSyncEngine, ensures the custom private zone, and
    /// bootstraps durable outbox rows into engine pending changes.
    public func start() async throws {
        guard engine == nil else { return }
        let userRecordID = try await container.userRecordID()
        let accountDigest = SHA256.hash(data: Data(userRecordID.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
        let accountDatabaseURL = baseDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent("authoring-v2-\(accountDigest).sqlite")
        try FileManager.default.createDirectory(at: accountDatabaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let accountStore = AuthoringLocalStore(databaseURL: accountDatabaseURL)
        try await accountStore.prepareForSync()
        store = accountStore
        let scope = "private:authoring-v2:\(accountDigest)"
        accountScope = scope
        let stateData = try await accountStore.engineState(scope: scope)
        let serializedState = try stateData.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serializedState,
            delegate: self
        )
        // Sync begins only from the explicit coordinator/UI call until account
        // scoping is fully enabled; this prevents a restored engine from sending
        // queued local work to a newly signed-in account at process launch.
        configuration.automaticallySync = false
        let syncEngine = CKSyncEngine(configuration)
        engine = syncEngine
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

        let mutations = try await accountStore.pendingMutations()
        let changes = Set(mutations.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0.entityId)) })
        syncEngine.state.add(pendingRecordZoneChanges: Array(changes))
    }

    /// Requests a foreground round trip. Changes remain queued if CloudKit is
    /// unavailable and are replayed from the SQLite outbox on the next start.
    public func synchronize() async throws {
        try await start()
        guard !pausedForAccountSwitch, let engine, let store else { throw AuthoringCloudKitError.accountTransition }
        lastFailure = nil
        try await engine.fetchChanges()
        guard !pausedForAccountSwitch else { throw AuthoringCloudKitError.accountTransition }
        try await engine.sendChanges()
        if let lastFailure { throw AuthoringCloudKitError.syncFailure(lastFailure) }
        let pendingMutations = try await store.pendingMutations()
        let pendingCount = pendingMutations.count
        guard pendingCount == 0 else { throw AuthoringCloudKitError.pendingMutations(pendingCount) }
    }

    /// Entry point for phone/Mac authoring repositories: persists the entity and
    /// outbox row locally before making it visible to CKSyncEngine.
    @discardableResult
    public func commitMutation(
        entityId: UUID, entityKind: String, payload: Data, changedFields: [String]
    ) async throws -> AuthoringMutation {
        try await start()
        guard let store, let engine, !pausedForAccountSwitch else { throw AuthoringCloudKitError.accountTransition }
        guard payload.count <= 512 * 1024,
              (try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])) != nil else {
            throw AuthoringCloudKitError.invalidPayload
        }
        let mutation = try await store.commitLocalMutation(
            entityId: entityId, entityKind: entityKind, payload: payload, changedFields: changedFields
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: entityId))])
        return mutation
    }

    /// Queues a project snapshot set with one engine startup and makes only
    /// changed records pending, so autosaves do not grow an identical outbox.
    public func commitMutations(_ snapshots: [AuthoringEntitySnapshot]) async throws {
        try await start()
        guard let store, let engine, !pausedForAccountSwitch else { throw AuthoringCloudKitError.accountTransition }
        var pending = Set<CKSyncEngine.PendingRecordZoneChange>()
        for snapshot in snapshots {
            guard snapshot.payload.count <= 512 * 1024,
                  (try? JSONSerialization.jsonObject(with: snapshot.payload, options: [.fragmentsAllowed])) != nil else {
                throw AuthoringCloudKitError.invalidPayload
            }
            if try await store.commitLocalMutationIfChanged(
                entityId: snapshot.id,
                entityKind: snapshot.kind,
                payload: snapshot.payload,
                changedFields: snapshot.changedFields
            ) != nil {
                pending.insert(.saveRecord(recordID(for: snapshot.id)))
            }
        }
        if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: Array(pending)) }
    }

    public func storedEntities() async throws -> [AuthoringStoredEntity] {
        try await start()
        guard let store else { throw AuthoringCloudKitError.accountTransition }
        return try await store.entities()
    }

    /// Call after the conflict-resolution flow has persisted the user's choice.
    public func retryResolvedEntity(_ entityId: UUID) async throws {
        guard let engine, let store, !pausedForAccountSwitch else { throw AuthoringCloudKitError.accountTransition }
        let hasConflicts = try await store.hasUnresolvedConflicts(entityId: entityId)
        guard !hasConflicts else { throw AuthoringCloudKitError.unresolvedConflict }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: entityId))])
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if fetchInProgress {
                deferredState = update.stateSerialization
            } else if !checkpointBlocked {
                await persistState(update.stateSerialization)
            }
        case .willFetchChanges:
            fetchInProgress = true
            fetchApplyFailed = false
        case .fetchedRecordZoneChanges(let changes):
            do {
                guard let store, let accountScope else { return }
                let records = try changes.modifications.map { try Self.decode($0.record) }
                    + changes.deletions.map { deletion in
                        AuthoringRemoteRecord(
                            id: try Self.entityID(deletion.recordID), kind: deletion.recordType,
                            changeTag: "deleted", payload: Data("null".utf8), isDeleted: true
                        )
                    }
                if !records.isEmpty {
                    try await store.applyRemotePage(scope: accountScope, pageId: UUID(), records: records, cursor: nil)
                }
            } catch {
                fetchApplyFailed = true
                checkpointBlocked = true
                // Do not checkpoint engine state after a failed inbox apply. The
                // previous serialized token causes CloudKit to replay this page.
                Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                    .error("Authoring v2 inbox apply failed: \(String(describing: error), privacy: .public)")
            }
        case .didFetchChanges:
            fetchInProgress = false
            if !fetchApplyFailed, let deferredState {
                self.deferredState = nil
                await persistState(deferredState)
                checkpointBlocked = false
            } else {
                // Preserve the previous CloudKit token. Restart then replays the
                // unapplied page rather than advancing past it.
                self.deferredState = nil
                checkpointBlocked = true
            }
        case .sentRecordZoneChanges(let changes):
            guard let store else { return }
            for record in changes.savedRecords {
                guard let entityID = UUID(uuidString: record.recordID.recordName),
                      let operationIDString = record["mutationID"] as? String,
                      let operationID = UUID(uuidString: operationIDString),
                      let changeTag = record.recordChangeTag,
                      let fields = Self.encodeSystemFields(record) else { continue }
                do {
                    try await store.acknowledgeUpload(entityId: entityID, operationId: operationID, changeTag: changeTag, systemFields: fields)
                } catch {
                    Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                        .error("Authoring v2 upload receipt persistence failed: \(String(describing: error), privacy: .public)")
                }
            }
            for failure in changes.failedRecordSaves {
                if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                    do {
                        guard let accountScope else { continue }
                        // Apply the server version through the same three-way
                        // reducer; never adopt its change tag and overwrite it.
                        try await store.applyRemotePage(scope: accountScope, pageId: UUID(), records: [try Self.decode(server)], cursor: nil)
                        guard let entityID = UUID(uuidString: failure.record.recordID.recordName) else { continue }
                        if try await store.hasUnresolvedConflicts(entityId: entityID) {
                            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                            lastFailure = .conflictPendingResolution
                        } else {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                        }
                    } catch {
                        Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                            .error("Authoring v2 conflict capture failed: \(String(describing: error), privacy: .public)")
                    }
                } else if failure.error.code == .unknownItem,
                          let entityID = UUID(uuidString: failure.record.recordID.recordName),
                          let kind = failure.record["entityKind"] as? String {
                    do {
                        guard let accountScope else { continue }
                        try await store.applyRemotePage(scope: accountScope, pageId: UUID(), records: [
                            AuthoringRemoteRecord(id: entityID, kind: kind, changeTag: "deleted", payload: Data("null".utf8), isDeleted: true)
                        ], cursor: nil)
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                        lastFailure = .conflictPendingResolution
                    } catch {
                        Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                            .error("Authoring v2 deletion conflict capture failed: \(String(describing: error), privacy: .public)")
                    }
                } else if failure.error.code == .zoneNotFound {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    lastFailure = .temporarilyUnavailable
                } else {
                    lastFailure = Self.failure(for: failure.error)
                }
            }
        case .sentDatabaseChanges(let changes):
            if let failure = changes.failedZoneSaves.first {
                lastFailure = Self.failure(for: failure.error)
                Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                    .error("Authoring v2 zone save failed: \(String(describing: failure.error), privacy: .public)")
            }
        case .accountChange(let change):
            switch change.changeType {
            case .switchAccounts, .signOut:
                // Local edits/outbox survive; require an explicit foreground
                // sync call after the account transition before sending again.
                pausedForAccountSwitch = true
                engine = nil
                store = nil
                accountScope = nil
            case .signIn:
                pausedForAccountSwitch = false
            @unknown default:
                pausedForAccountSwitch = true
                engine = nil
            }
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let store else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        guard var batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending, recordProvider: { [store, zoneID] recordID in
            guard recordID.zoneID == zoneID,
                  let entityID = UUID(uuidString: recordID.recordName),
                  let mutations = try? await store.pendingMutations(),
                  let mutation = mutations.last(where: { $0.entityId == entityID }) else { return nil }
            let systemFields = try? await store.systemFields(entityId: entityID)
            let record = systemFields.flatMap(Self.restoreRecord(from:))
                ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            record["protocolVersion"] = Int64(AuthoringProtocol.version) as CKRecordValue
            record["entityID"] = entityID.uuidString as CKRecordValue
            record["entityKind"] = mutation.entityKind as CKRecordValue
            record["payloadJSON"] = String(decoding: mutation.payload, as: UTF8.self) as CKRecordValue
            record["mutationID"] = mutation.operationId.uuidString as CKRecordValue
            record["payloadSHA256"] = mutation.payloadSha256 as CKRecordValue
            return record
        }) else { return nil }
        batch.atomicByZone = true
        return batch
    }

    private func persistState(_ state: CKSyncEngine.State.Serialization) async {
        do {
            guard let store, let accountScope else { return }
            try await store.saveEngineState(scope: accountScope, state: JSONEncoder().encode(state))
        } catch {
            Logger(subsystem: "guru.parso.voxglass", category: "AuthoringV2Sync")
                .error("Authoring v2 engine checkpoint failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func failure(for error: CKError) -> AuthoringCloudKitFailure {
        switch error.code {
        case .quotaExceeded: .quotaExceeded
        case .notAuthenticated, .accountTemporarilyUnavailable: .reauthenticationRequired
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .zoneBusy: .temporarilyUnavailable
        default: .other(code: error.code.rawValue)
        }
    }

    private func recordID(for id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString, zoneID: zoneID) }

    private static func entityID(_ id: CKRecord.ID) throws -> UUID {
        guard let uuid = UUID(uuidString: id.recordName) else { throw AuthoringCloudKitError.invalidEntityID(id.recordName) }
        return uuid
    }

    private static func decode(_ record: CKRecord) throws -> AuthoringRemoteRecord {
        guard record.recordType == recordType,
              (record["protocolVersion"] as? NSNumber)?.intValue == AuthoringProtocol.version,
              let kind = record["entityKind"] as? String,
              let payload = record["payloadJSON"] as? String,
              let changeTag = record.recordChangeTag,
              let systemFields = encodeSystemFields(record) else { throw AuthoringCloudKitError.invalidRecord }
        return AuthoringRemoteRecord(
            id: try entityID(record.recordID), kind: kind, changeTag: changeTag,
            payload: Data(payload.utf8), systemFields: systemFields
        )
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data? {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func restoreRecord(from data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

public enum AuthoringCloudKitError: Error, Sendable {
    case invalidEntityID(String)
    case invalidRecord
    case accountTransition
    case invalidPayload
    case unresolvedConflict
    case syncFailure(AuthoringCloudKitFailure)
    case pendingMutations(Int)
}

extension AuthoringCloudKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEntityID(let id): "CloudKit returned an invalid narration entity ID: \(id)."
        case .invalidRecord: "CloudKit returned a narration record with an unsupported format."
        case .accountTransition: "The iCloud account changed. Try narration sync again."
        case .invalidPayload: "A narration project record is too large or invalid to sync."
        case .unresolvedConflict: "Resolve the narration sync conflict before trying again."
        case .syncFailure(let failure): failure.errorDescription
        case .pendingMutations(let count): "iCloud left \(count) narration change\(count == 1 ? "" : "s") pending. Try again shortly."
        }
    }
}

public enum AuthoringCloudKitFailure: Sendable, Equatable, LocalizedError {
    case quotaExceeded
    case reauthenticationRequired
    case temporarilyUnavailable
    case conflictPendingResolution
    case other(code: Int)

    public var errorDescription: String? {
        switch self {
        case .quotaExceeded: "Your iCloud account is out of storage. Narration sync could not finish."
        case .reauthenticationRequired: "Sign in to iCloud on this device, then try narration sync again."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Narration changes are saved locally; try again shortly."
        case .conflictPendingResolution: "A narration project has a sync conflict that needs to be resolved."
        case .other(let code): "iCloud could not save narration project data (CloudKit error \(code))."
        }
    }
}
#endif
