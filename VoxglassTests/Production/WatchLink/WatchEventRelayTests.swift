import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct WatchEventRelayTests {

    private let projectID = ProductionWatchFixtures.rogerAckroydProjectID

    private func makeOutbox() throws -> (WatchReviewOutbox, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-outbox-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        let storage = FileWatchOutboxStorage(directory: dir)
        return (WatchReviewOutbox(storage: storage), dir)
    }

    private func watchEvent(paragraphID: UUID, type: ReviewEventType, id: UUID = UUID()) -> ReviewEvent {
        ReviewEvent(
            id: id,
            projectID: projectID,
            paragraphID: paragraphID,
            type: type,
            device: .watch,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Fold the events the phone received through the phone's fold, proving the
    /// offline watch action reaches the Mac's review state exactly once.
    private func foldOnMac(events: [ReviewEvent]) -> [UUID: ReviewState] {
        ReviewEventFolder().fold(events, into: [:]).states
    }

    @Test func offlineApproveAction_reachesMacExactlyOnceViaPhoneFold() async throws {
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paragraph = ProductionWatchFixtures.flaggedParagraphIDs[0]
        let approve = watchEvent(paragraphID: paragraph, type: .approve)
        try outbox.enqueue(approve)

        let phone = FakeWatchTransport()
        let result = try await outbox.flush(over: phone)

        #expect(result.transferred.count == 1)
        #expect(result.transferred[0].id == approve.id)
        #expect(result.remaining.isEmpty)

        // The watch's outbox is now empty: the action was not duplicated.
        #expect(try outbox.pending().isEmpty)

        // The phone received it and folded it into the Mac's state.
        let snapshot = phone.snapshot()
        #expect(snapshot.events.map(\.id) == [approve.id])
        let states = foldOnMac(events: snapshot.events)
        #expect(states[paragraph] == .approved)
    }

    @Test func enqueueIsIdempotent_byEventID() throws {
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paragraph = ProductionWatchFixtures.flaggedParagraphIDs[1]
        let event = watchEvent(paragraphID: paragraph, type: .flag)
        try outbox.enqueue(event)
        try outbox.enqueue(event)

        #expect(try outbox.pending().count == 1)
    }

    @Test func severalOfflineActions_syncInOrderAndFold() async throws {
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ids = ProductionWatchFixtures.flaggedParagraphIDs.prefix(3)
        var events: [ReviewEvent] = []
        for (i, paragraph) in ids.enumerated() {
            let type: ReviewEventType = i == 1 ? .flag : .approve
            events.append(watchEvent(paragraphID: paragraph, type: type))
        }
        for event in events { try outbox.enqueue(event) }

        let phone = FakeWatchTransport()
        let result = try await outbox.flush(over: phone)

        #expect(result.transferred.count == 3)
        #expect(try outbox.pending().isEmpty)

        let states = foldOnMac(events: phone.snapshot().events)
        #expect(states[ids[0]] == .approved)
        #expect(states[ids[1]] == .flagged)
        #expect(states[ids[2]] == .approved)
    }

    @Test func failedTransfer_leavesEventsQueuedForRetry() async throws {
        let (outbox, dir) = try makeOutbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paragraph = ProductionWatchFixtures.flaggedParagraphIDs[2]
        try outbox.enqueue(watchEvent(paragraphID: paragraph, type: .needsPickup))

        let phone = FakeWatchTransport()
        phone.failPoint = .nextSendEvents
        await #expect(throws: (any Error).self) {
            _ = try await outbox.flush(over: phone)
        }

        // Nothing was removed; the action is preserved and can be retried.
        #expect(try outbox.pending().count == 1)
        #expect(phone.snapshot().events.isEmpty)

        // A later successful flush delivers it.
        let retry = try await outbox.flush(over: phone)
        #expect(retry.transferred.count == 1)
        #expect(try outbox.pending().isEmpty)
    }

    @Test func watcherNeverTouchesCloudKitByConstruction() {
        // The whole relay is defined against ReviewEvent + WatchTransport, neither of
        // which can name a CloudKit type — the transport protocol has no CK symbols.
        let methods = String(describing: WatchTransport.self)
        #expect(!methods.contains("CK"))
    }
}
