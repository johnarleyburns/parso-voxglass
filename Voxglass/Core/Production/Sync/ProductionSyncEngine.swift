import Foundation

/// The sync engine: publishes projections (Mac writer), fetches zone changes and
/// returns decoded records (both sides), pushes review events (phone), and recovers
/// stale change tokens (spec §13.5, §13.7). CloudKit-free by construction; concrete
/// `ProductionSyncTransport` implementations live in the app targets.
public actor ProductionSyncEngine {

    public struct Configuration: Sendable {
        public var recordBatchSize: Int
        public var maxAssetTransfersPerBatch: Int
        public var backoffBase: TimeInterval
        public var backoffCap: TimeInterval
        public var maxAttempts: Int
        public var sleeper: @Sendable (TimeInterval) async -> Void
        public var randomJitter: @Sendable () -> Double

        public init(
            recordBatchSize: Int = 100,
            maxAssetTransfersPerBatch: Int = 20,
            backoffBase: TimeInterval = 2,
            backoffCap: TimeInterval = 120,
            maxAttempts: Int = 4,
            sleeper: @escaping @Sendable (TimeInterval) async -> Void = { delay in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            },
            randomJitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
        ) {
            self.recordBatchSize = recordBatchSize
            self.maxAssetTransfersPerBatch = maxAssetTransfersPerBatch
            self.backoffBase = backoffBase
            self.backoffCap = backoffCap
            self.maxAttempts = maxAttempts
            self.sleeper = sleeper
            self.randomJitter = randomJitter
        }
    }

    private let transport: any ProductionSyncTransport
    private let state: any SyncStateStore
    private let config: Configuration
    private let codec = ProjectionRecordCodec()

    public init(
        transport: any ProductionSyncTransport,
        state: any SyncStateStore,
        config: Configuration = Configuration()
    ) {
        self.transport = transport
        self.state = state
        self.config = config
    }

    // MARK: - Publish (Mac writer)

    /// Publishes the delta between the last snapshot and the current project.
    /// Only changed records are pushed (spec §13.5). Returns `.withdrawn` when the
    /// project was hidden, `.noChanges` when the projection is identical.
    public func publish(
        project: AudiobookProject,
        counts: ProjectCounts,
        watchPinnedParagraphIDs: [UUID] = [],
        latestNotes: [UUID: ReviewNote] = [:]
    ) async throws -> PublishOutcome {
        let policy = ProjectionPolicy(
            includeSourceText: project.profile.includeSourceTextInProjection,
            proxyBitrateKbps: project.profile.proxyBitrateKbps
        )
        let builder = ProjectionBuilder(policy: policy)
        let old = try await state.projectionSnapshot(projectID: project.id)

        guard let base = builder.projection(
            from: project,
            counts: counts,
            revision: old?.revision ?? 0,
            watchPinnedParagraphIDs: watchPinnedParagraphIDs,
            latestNotes: latestNotes
        ) else {
            // Hidden project: withdraw anything already published (§13.3 rule 4).
            if let old, !old.project.isHiddenFromDevices {
                let names = codec.records(from: old).map(\.recordName)
                try await withTransientRetry { try await self.transport.deleteRecords(names) }
                try await state.setProjectionSnapshot(nil, projectID: project.id)
            }
            return .withdrawn
        }

        var diff = ProjectionDiff.diff(old: old, new: base)
        if diff.isEmpty {
            return .noChanges
        }

        // Bump the revision and re-derive the delta so the published snapshot is
        // self-consistent (spec: "revision increments on every successful publish").
        let revision = (old?.revision ?? 0) + 1
        guard let final = builder.projection(
            from: project,
            counts: counts,
            revision: revision,
            watchPinnedParagraphIDs: watchPinnedParagraphIDs,
            latestNotes: latestNotes
        ) else {
            return .withdrawn
        }
        diff = ProjectionDiff.diff(old: old, new: final)

        var adoptedRevision: Int?
        try await pushChanges(diff, adoptedRevision: &adoptedRevision)

        if let adoptedRevision {
            var finalWithAdopted = final
            finalWithAdopted.revision = adoptedRevision
            finalWithAdopted.project.projectionRevision = adoptedRevision
            try await state.setProjectionSnapshot(finalWithAdopted, projectID: project.id)
        } else {
            try await state.setProjectionSnapshot(final, projectID: project.id)
        }

        let assets = diff.filter(\.proxyNeeded).count
        return .published(revision: adoptedRevision ?? revision, recordsPushed: diff.count, assetsPushed: assets)
    }

    // MARK: - Fetch (both sides)

    /// Fetches zone changes, decodes events and the projection, and persists the new
    /// token. A stale change token is discarded and the zone refetched from scratch
    /// without surfacing an error (spec §13.7; `SyncTokenRecoveryTests`).
    public func pump() async throws -> IngestReport {
        var token = try await state.changeToken()
        var records: [SyncRecord] = []
        var deletedNames: [String] = []
        var fullRefetchUsed = false
        var moreComing = true

        while moreComing {
            var result = try await fetch(token)
            if result.changeTokenExpired {
                fullRefetchUsed = true
                try await state.setChangeToken(nil)
                token = nil
                result = try await fetch(nil)
            }
            records += result.records
            deletedNames += result.deletedRecordNames
            if let newToken = result.newToken { token = newToken }
            moreComing = result.moreComing
        }

        try await state.setChangeToken(token)

        var events: [ReviewEvent] = []
        var eventNames: [String] = []
        var proxyAssets: [UUID: Data] = [:]
        for record in records {
            if record.recordType == ProductionRecordType.event.rawValue {
                if let event = codec.event(from: record) {
                    events.append(event)
                    eventNames.append(record.recordName)
                }
            } else if record.recordType == ProductionRecordType.paragraph.rawValue,
                      let id = record.fields[ProductionField.paragraphID]?.stringValue().flatMap(UUID.init(uuidString:)),
                      let data = record.assetFields[ProductionAssetField.proxy] {
                proxyAssets[id] = data
            }
        }

        let projection = codec.projection(from: records)
        return IngestReport(
            events: events,
            eventRecordNames: eventNames,
            projection: projection,
            proxyAssets: proxyAssets,
            deletedParagraphNames: deletedNames.filter { $0.hasPrefix("para-") },
            fullRefetchUsed: fullRefetchUsed
        )
    }

    /// Deletes consumed `VGReviewEvent` records after the Mac has applied and folded
    /// them (spec §13.7: "they are a queue, not a log of record").
    public func deleteConsumedEvents(_ recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        try await withTransientRetry { try await self.transport.deleteRecords(recordNames) }
    }

    /// Pushes review events (phone side, from its outbox). Idempotent by event id.
    public func pushEvents(_ events: [ReviewEvent]) async throws {
        guard !events.isEmpty else { return }
        let records = events.map { codec.eventRecord(from: $0) }
        try await withTransientRetry { try await self.transport.pushRecords(records) }
    }

    // MARK: - Internals

    private func fetch(_ token: SyncChangeToken?) async throws -> ZoneFetchResult {
        do {
            return try await withTransientRetry { try await self.transport.fetchZoneChanges(after: token) }
        } catch let error as SyncError where error == .changeTokenExpired {
            return ZoneFetchResult(changeTokenExpired: true)
        }
    }

    private func pushChanges(_ diff: [ProjectionDiff.Change], adoptedRevision: inout Int?) async throws {
        let deletes = diff.filter { $0.kind == .delete }.map(\.recordName)
        if !deletes.isEmpty {
            try await withTransientRetry { try await self.transport.deleteRecords(deletes) }
        }

        let upserts = diff.filter { $0.kind == .upsert }.map { change in
            SyncRecord(recordType: change.recordType, recordName: change.recordName, fields: change.fields)
        }
        for batch in chunks(upserts, size: config.recordBatchSize) {
            let result = try await pushBatch(batch)
            if let adopted = result.adoptedRevision { adoptedRevision = adopted }
        }
    }

    private struct PushResult {
        var assets: Int
        var adoptedRevision: Int?
    }

    private func pushBatch(_ batch: [SyncRecord]) async throws -> PushResult {
        try await withTransientRetry {
            var records = batch
            do {
                try await self.transport.pushRecords(records)
            } catch SyncError.serverRecordChanged(let name, let tag, let serverRevision) {
                // Retry once with the server record's change tag (the Mac is the only
                // writer; this is nearly always a duplicate-publish race with itself).
                // For a project record, adopt the server's revision (last-writer-wins).
                var adopted: Int?
                if let index = records.firstIndex(where: { $0.recordName == name }) {
                    records[index].recordChangeTag = tag
                    if records[index].recordType == ProductionRecordType.project.rawValue, let serverRevision {
                        let local = records[index].fields[ProductionField.revision]?.int64Value() ?? 0
                        let revision = max(local, serverRevision + 1)
                        records[index].fields[ProductionField.revision] = .int64(revision)
                        adopted = Int(revision)
                    }
                }
                try await self.transport.pushRecords(records)
                return PushResult(assets: records.filter(\.assetCarrying).count, adoptedRevision: adopted)
            }
            return PushResult(assets: records.filter(\.assetCarrying).count, adoptedRevision: nil)
        }
    }

    private func withTransientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        var backoff = config.backoffBase
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < config.maxAttempts, isTransient(error) else { throw error }
                attempt += 1
                let requested = (error as? SyncError)?.retryAfterSeconds
                let base = requested ?? backoff
                let delay = base * config.randomJitter()
                await config.sleeper(delay)
                backoff = min(backoff * 2, config.backoffCap)
            }
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        switch error {
        case let error as SyncError:
            switch error {
            case .transient, .zoneNotFound:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func chunks<T>(_ elements: [T], size: Int) -> [[T]] {
        guard size > 0, !elements.isEmpty else { return [] }
        return stride(from: 0, to: elements.count, by: size).map { index in
            Array(elements[index..<min(index + size, elements.count)])
        }
    }
}

private extension SyncRecord {
    var assetCarrying: Bool {
        recordType == ProductionRecordType.paragraph.rawValue
            && fields[ProductionField.proxySHA] != nil
    }
}

private extension SyncError {
    var retryAfterSeconds: TimeInterval? {
        if case let .transient(_, retryAfter) = self { return retryAfter }
        return nil
    }
}
