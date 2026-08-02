// CloudKit is available on watchOS, but the watch must NEVER touch CloudKit
// (spec §13.6 rule 1, gate G-5). Guard the concrete transport to iOS/macOS only;
// the watch compiles this file to nothing.
#if os(iOS) || os(macOS)

import Foundation
import CloudKit
import os

/// Concrete `ProductionSyncTransport` over the private CloudKit database and the
/// shared `VGProductionZone` (spec §13.2). The writer transport (Mac): maps
/// `SyncRecord` to/from `CKRecord`, attaches paragraph proxies as `CKAsset`, and
/// surfaces server-record conflicts with the server change tag + revision so the
/// engine can adopt and retry. The phone consumer uses the same transport.
public actor CloudKitProductionSync: ProductionSyncTransport {

    public static let zoneName = "VGProductionZone"
    public static let containerID = "iCloud.guru.parso.voxglass"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let codec = ProjectionRecordCodec()
    /// Resolves a proxy SHA to a file the CKAsset can be backed by (Studio cache).
    private let proxyFileProvider: @Sendable (String) async throws -> URL?

    public init(
        containerID: String = CloudKitProductionSync.containerID,
        proxyFileProvider: @escaping @Sendable (String) async throws -> URL? = { _ in nil }
    ) {
        self.container = CKContainer(identifier: containerID)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.proxyFileProvider = proxyFileProvider
    }

    // MARK: - ProductionSyncTransport

    public func accountStatus() async -> SyncAccountStatus {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<CKAccountStatus, Never>) in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
        switch status {
        case .available: return .available
        case .noAccount, .restricted: return .notAuthenticated
        case .temporarilyUnavailable: return .unavailable
        case .couldNotDetermine: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public func fetchZoneChanges(after token: SyncChangeToken?) async throws -> ZoneFetchResult {
        try await ensureZoneExists()
        let serverToken: CKServerChangeToken?
        if let token {
            serverToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token.data)
        } else {
            serverToken = nil
        }

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: serverToken,
            resultsLimit: 200,
            desiredKeys: nil
        )
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config]
        )

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZoneFetchResult, Error>) in
            var changed: [SyncRecord] = []
            var deleted: [String] = []
            var newTokenData: Data?
            var expired = false
            let lock = NSLock()

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    changed.append(Self.record(from: record))
                    lock.unlock()
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                lock.lock()
                deleted.append(recordID.recordName)
                lock.unlock()
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                guard let token else { return }
                lock.lock()
                newTokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                lock.unlock()
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                        lock.lock()
                        expired = true
                        lock.unlock()
                    }
                case .success:
                    break
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    let outcome = ZoneFetchResult(
                        records: changed,
                        deletedRecordNames: deleted,
                        newToken: newTokenData.map { SyncChangeToken(data: $0) },
                        moreComing: false,
                        changeTokenExpired: expired
                    )
                    continuation.resume(returning: outcome)
                case .failure(let error):
                    continuation.resume(throwing: Self.mapError(error))
                }
            }

            self.database.add(operation)
        }
    }

    public func pushRecords(_ records: [SyncRecord]) async throws {
        try await ensureZoneExists()
        var ckRecords = try await Self.records(from: records, proxyFileProvider: proxyFileProvider)

        do {
            try await pushCKRecords(ckRecords)
        } catch SyncError.serverRecordChanged(let name, _, let serverRevision) {
            // Retry once: adopt the server record (which carries the winning change
            // tag) and, for the project record, last-writer-wins on revision (§13.7).
            guard let index = ckRecords.firstIndex(where: { $0.recordID.recordName == name }),
                  let server = serverRecordCache.record(named: name) else {
                throw SyncError.serverRecordChanged(recordName: name, serverChangeTag: "", serverRevision: serverRevision)
            }
            var adopted = server
            adopted["revision"] = ckRecords[index]["revision"]
            if ckRecords[index].recordType == ProductionRecordType.project.rawValue, let serverRevision {
                let local = (ckRecords[index]["revision"] as? NSNumber)?.int64Value ?? 0
                adopted["revision"] = max(local, serverRevision + 1) as NSNumber
            }
            ckRecords[index] = adopted
            try await pushCKRecords(ckRecords)
        }
    }

    private let serverRecordCache = ServerRecordCacheBox()

    private func pushCKRecords(_ ckRecords: [CKRecord]) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.perRecordSaveBlock = { [cache = serverRecordCache] recordID, result in
                if case .failure(let error) = result, let ckError = error as? CKError,
                   ckError.code == .serverRecordChanged, let server = ckError.serverRecord {
                    cache.store(server, for: recordID.recordName)
                }
            }
            operation.modifyRecordsResultBlock = { [cache = serverRecordCache] result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged,
                       let server = ckError.serverRecord {
                        cache.store(server, for: server.recordID.recordName)
                    }
                    continuation.resume(throwing: Self.mapError(error))
                }
            }
            self.database.add(operation)
        }
    }

    public func deleteRecords(_ recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        try await ensureZoneExists()
        let ids = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: Self.mapError(error))
                }
            }
            self.database.add(operation)
        }
    }

    // MARK: - Mapping

    private static func record(from ckRecord: CKRecord) -> SyncRecord {
        var fields: [String: SyncFieldValue] = [:]
        var assets: [String: Data] = [:]
        for (key, value) in ckRecord {
            switch value {
            case let string as String:
                fields[key] = .string(string)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    fields[key] = .int64(number.boolValue ? 1 : 0)
                } else {
                    fields[key] = .int64(number.int64Value)
                }
            case let date as Date:
                fields[key] = .date(date)
            case let array as [String]:
                fields[key] = .stringList(array)
            case let asset as CKAsset:
                if let url = asset.fileURL, let data = try? Data(contentsOf: url) {
                    assets[key] = data
                }
            default:
                break
            }
        }
        return SyncRecord(
            recordType: ckRecord.recordType,
            recordName: ckRecord.recordID.recordName,
            parentName: (ckRecord.parent as? CKRecord.Reference)?.recordID.recordName,
            fields: fields,
            recordChangeTag: ckRecord.recordChangeTag,
            assetFields: assets
        )
    }

    private static func records(
        from syncRecords: [SyncRecord],
        proxyFileProvider: @Sendable (String) async throws -> URL?
    ) async throws -> [CKRecord] {
        var result: [CKRecord] = []
        for record in syncRecords {
            let ck = CKRecord(recordType: record.recordType, recordID: .init(recordName: record.recordName))
            for (key, value) in record.fields {
                switch value {
                case .string(let string): ck[key] = string
                case .int64(let int): ck[key] = int as NSNumber
                case .double(let double): ck[key] = double as NSNumber
                case .date(let date): ck[key] = date
                case .stringList(let list): ck[key] = list
                }
            }
            if let parent = record.parentName {
                ck.parent = CKRecord.Reference(
                    recordID: .init(recordName: parent, zoneID: ck.recordID.zoneID),
                    action: .none
                )
            }
            // `CKRecord.recordChangeTag` is get-only; conflict retries adopt the
            // server record from `ServerRecordCacheBox` instead.
            // Attach the paragraph proxy as a CKAsset when one is required.
            if record.recordType == ProductionRecordType.paragraph.rawValue,
               let sha = record.fields[ProductionField.proxySHA]?.stringValue(),
               let url = try await proxyFileProvider(sha) {
                ck[ProductionAssetField.proxy] = CKAsset(fileURL: url)
            }
            result.append(ck)
        }
        return result
    }

    private static func mapError(_ error: Error) -> Error {
        guard let ckError = error as? CKError else { return error }

        // A whole-batch conflict.
        if ckError.code == .serverRecordChanged {
            return serverConflict(from: ckError)
        }

        // Partial failures: find the first record that conflicted.
        if ckError.code == .partialFailure,
           let partials = ckError.partialErrorsByItemID as? [CKRecord.ID: Error] {
            for (_, partial) in partials {
                if let sub = partial as? CKError, sub.code == .serverRecordChanged {
                    return serverConflict(from: sub)
                }
            }
            if partials.values.allSatisfy({ ($0 as? CKError)?.code == .unknownItem }) {
                return SyncError.transient(reason: "records already deleted", retryAfterSeconds: nil)
            }
            return SyncError.transient(reason: "batch partial failure", retryAfterSeconds: ckError.retryAfterSeconds)
        }

        switch ckError.code {
        case .changeTokenExpired:
            return SyncError.changeTokenExpired
        case .zoneNotFound, .userDeletedZone:
            return SyncError.zoneNotFound
        case .quotaExceeded:
            return SyncError.quotaExceeded
        case .notAuthenticated:
            return SyncError.auth
        case .networkUnavailable, .networkFailure, .requestRateLimited, .serviceUnavailable:
            return SyncError.transient(reason: ckError.localizedDescription, retryAfterSeconds: ckError.retryAfterSeconds)
        default:
            return SyncError.transport(ckError.localizedDescription)
        }
    }

    private static func serverConflict(from ckError: CKError) -> Error {
        let recordName = ckError.serverRecord?.recordID.recordName ?? ""
        let tag = ckError.serverRecord?.recordChangeTag ?? ""
        let revision = (ckError.serverRecord?["revision"] as? NSNumber)?.int64Value
        return SyncError.serverRecordChanged(recordName: recordName, serverChangeTag: tag, serverRevision: revision)
    }

    // MARK: - Zone + subscription

    private func ensureZoneExists() async throws {
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zoneID)], recordZoneIDsToDelete: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operation.modifyRecordZonesResultBlock = { result in
                if case .failure(let error) = result {
                    Self.logError("zone creation reported failure — \(error)")
                }
                continuation.resume()
            }
            database.add(operation)
        }
    }

    /// Registers the silent-push zone subscription (idempotent per process run).
    public func ensureSubscription() async {
        let subscriptionID = "production-zone-subscription"
        let defaultsKey = "voxglass.production.zoneSubscribed.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsKey) else { return }

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: nil
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    defaults.set(true, forKey: defaultsKey)
                case .failure(let error):
                    Self.logError("subscription failed — \(error)")
                }
                continuation.resume()
            }
            database.add(operation)
        }
    }

    private static func logError(_ message: String) {
        os.Logger(subsystem: "guru.parso.voxglass.studio", category: "cloudkit-production").error("\(message, privacy: .public)")
    }
}

/// Lock-protected store of server records returned by `.serverRecordChanged`, so a
/// conflict retry can push the record that carries the server's change tag
/// (`CKRecord.recordChangeTag` is get-only, so a fresh record cannot carry it).
private final class ServerRecordCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: CKRecord] = [:]

    func store(_ record: CKRecord, for recordName: String) {
        lock.lock(); defer { lock.unlock() }
        records[recordName] = record
    }

    func record(named recordName: String) -> CKRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[recordName]
    }
}

#endif // os(iOS) || os(macOS)
