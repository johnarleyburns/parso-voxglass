import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct OfflineEventQueueTests {

    private let projectID = UUID(uuidString: "6C6B36F5-0000-0000-0000-000000000001")!

    private func makeEngine(transport: FakeProductionSyncTransport) throws -> ProductionSyncEngine {
        let config = ProductionSyncEngine.Configuration(
            sleeper: { _ in },
            randomJitter: { 1.0 }
        )
        return ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: config)
    }

    private func makeOutbox() throws -> (ReviewEventOutbox, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-outbox-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: directory)
        let storage = FileWatchOutboxStorage(directory: directory)
        return (ReviewEventOutbox(storage: storage), directory)
    }

    private func event(paragraphID: UUID, type: ReviewEventType, at time: TimeInterval = 1_700_000_000) -> ReviewEvent {
        ReviewEvent(
            id: UUID(),
            projectID: projectID,
            paragraphID: paragraphID,
            type: type,
            device: .iPhone,
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    @Test func offlineEvents_syncExactlyOnce_afterReconnect() async throws {
        let transport = FakeProductionSyncTransport()
        let engine = try makeEngine(transport: transport)
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paragraph = UUID()
        // Airplane mode: transport is unreachable, so every push fails.
        transport.accountStatusValue = .unavailable
        try outbox.enqueue(event(paragraphID: paragraph, type: .flag))
        try outbox.enqueue(event(paragraphID: paragraph, type: .addNote, at: 1_700_000_001))
        try outbox.enqueue(event(paragraphID: paragraph, type: .approve, at: 1_700_000_002))
        #expect(try outbox.pending().count == 3)

        // Offline flush keeps everything queued (nothing lost).
        transport.accountStatusValue = .unavailable
        do {
            _ = try await outbox.flush(over: engine)
        } catch {}
        #expect(try outbox.pending().count == 3)

        // Reconnect: everything pushes once and the outbox drains.
        transport.accountStatusValue = .available
        let result = try await outbox.flush(over: engine)
        #expect(result.pushed.count == 3)
        #expect(result.remaining.isEmpty)
        #expect(try outbox.pending().isEmpty)

        // The transport received exactly three event records, once each.
        let records = transport.pushedEventRecords()
        #expect(records.count == 3)
        #expect(Set(records.map { $0.fields["type"]?.stringValue() }) == Set(["flag", "addNote", "approve"]))

        // The Mac folds by (createdAt, id), so the arrival order in a single batch
        // does not matter — only the timestamps do. Assert timestamp ordering.
        let codec = ProjectionRecordCodec()
        let orderedTypes = records
            .compactMap { codec.event(from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.type.rawValue)
        #expect(orderedTypes == ["flag", "addNote", "approve"])

        // A second flush pushes nothing: exactly once, never duplicated.
        let second = try await outbox.flush(over: engine)
        #expect(second.pushed.isEmpty)
        #expect(transport.pushedEventRecords().count == 3)
    }

    @Test func transientFailure_leavesOutboxIntact_thenPushesOnce() async throws {
        let transport = FakeProductionSyncTransport()
        transport.transientFailuresRemaining = 1
        let engine = try makeEngine(transport: transport)
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paragraph = UUID()
        try outbox.enqueue(event(paragraphID: paragraph, type: .needsPickup))

        // First flush: the engine retries the transient once and succeeds.
        let result = try await outbox.flush(over: engine)
        #expect(result.pushed.count == 1)
        #expect(transport.pushedEventRecords().count == 1)
        #expect(try outbox.pending().isEmpty)
    }

    @Test func enqueueIsIdempotent_byEventID() throws {
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let e = event(paragraphID: UUID(), type: .flag)
        try outbox.enqueue(e)
        try outbox.enqueue(e)
        #expect(try outbox.pending().count == 1)
    }

    @Test func macFold_appliesOfflineSequenceExactlyOnce() throws {
        // Flow D (§14.5): flag → note → approve on one paragraph yields one final
        // state (.approved) with exactly one note.
        let paragraph = UUID()
        let flag = event(paragraphID: paragraph, type: .flag, at: 1_700_000_000)
        var note = event(paragraphID: paragraph, type: .addNote, at: 1_700_000_001)
        note.noteText = "Breath here"
        let approve = event(paragraphID: paragraph, type: .approve, at: 1_700_000_002)

        let folder = ReviewEventFolder()
        let first = folder.fold([flag, note, approve], into: [:])
        #expect(first.states[paragraph] == .approved)
        #expect(first.notesToInsert.count == 1)

        // The fold is deterministic and idempotent: re-folding the same event set
        // (what a retried push would re-deliver, before the store's INSERT OR IGNORE
        // dedupes by event id) produces the identical final state and note.
        let again = folder.fold([flag, note, approve], into: [:])
        #expect(again.states == first.states)
        #expect(again.notesToInsert.map(\.text) == first.notesToInsert.map(\.text))
    }
}
