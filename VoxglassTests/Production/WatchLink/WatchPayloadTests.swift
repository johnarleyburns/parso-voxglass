import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct WatchPayloadTests {

    @Test func resolvedQueuePayload_roundTripsThroughJSON() throws {
        let payload = ProductionWatchFixtures.flaggedQueue()
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ResolvedQueuePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.paragraphIDs.count == 18)
        #expect(decoded.projectTitle == ProductionWatchFixtures.rogerAckroydTitle)
    }

    @Test func watchAudioItem_roundTripsThroughJSON() throws {
        let item = WatchAudioItem(paragraphID: UUID(), sha256: "abc", byteCount: 123, fileURL: URL(string: "file:///tmp/a.wav"))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WatchAudioItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func fixtures_smokeSeedCarriesExpectedCounts() {
        let seed = ProductionWatchFixtures.watchQueueSeed()
        #expect(seed.summaries.count == 1)
        #expect(seed.summaries[0].flaggedCount == 18)
        #expect(seed.queue.paragraphIDs.count == 18)
        #expect(seed.queue.queueLabel == "Flagged")
        #expect(seed.audio.count == 18)
    }

    @Test func audioFor_currentPlusNext_inStreamingMode() {
        let queue = ProductionWatchFixtures.flaggedParagraphIDs
        let resolver = WatchQueueAudioResolver()
        #expect(resolver.eagerParagraphIDs(queue: queue, currentIndex: 0, mode: .streaming) == [queue[0], queue[1]])
        #expect(resolver.eagerParagraphIDs(queue: queue, currentIndex: 5, mode: .streaming) == [queue[5], queue[6]])
        #expect(resolver.eagerParagraphIDs(queue: queue, currentIndex: 17, mode: .streaming) == [queue[17]])
    }

    @Test func audioFor_allWhenOfflineQueuePrepared() {
        let queue = ProductionWatchFixtures.flaggedParagraphIDs
        let resolver = WatchQueueAudioResolver()
        #expect(resolver.eagerParagraphIDs(queue: queue, currentIndex: 0, mode: .offlineQueuePrepared) == queue)
    }

    @Test func audioFor_emptyQueue_returnsEmpty() {
        let resolver = WatchQueueAudioResolver()
        #expect(resolver.eagerParagraphIDs(queue: [], currentIndex: 0, mode: .streaming).isEmpty)
    }

    @Test func audioFor_outOfBoundsIndex_isClamped() {
        let queue = ProductionWatchFixtures.flaggedParagraphIDs
        let resolver = WatchQueueAudioResolver()
        #expect(resolver.eagerParagraphIDs(queue: queue, currentIndex: 100, mode: .streaming) == [queue[17]])
    }
}

@Suite struct WatchRelayMessageContractTests {

    /// The phone and watch must agree on the `reviewEvent` wire format: the watch
    /// encodes a `ReviewEvent` as a `transferUserInfo` payload under the production
    /// action namespace, and the phone-side transport decodes the same action and
    /// payload to enqueue it for the Mac (spec §13.6, §18.2.8).
    @Test func reviewEvent_roundTripsThroughProductionActionMessage() throws {
        let event = ReviewEvent(
            id: UUID(),
            projectID: ProductionWatchFixtures.rogerAckroydProjectID,
            paragraphID: ProductionWatchFixtures.flaggedParagraphIDs[0],
            type: .approve,
            noteText: nil,
            tag: nil,
            device: .watch,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let message = try WatchPhoneMessageCodec.message(
            action: ProductionTransportAction.reviewEvent,
            payload: event
        )

        #expect(WatchPhoneMessageCodec.action(from: message) == ProductionTransportAction.reviewEvent)
        let decoded = try WatchPhoneMessageCodec.payload(ReviewEvent.self, from: message)
        #expect(decoded == event)
        #expect(decoded.device == .watch)
    }
}

@Suite struct WatchProductionStoragePolicyTests {

    private func item(_ id: UUID, bytes: Int, ageSeconds: TimeInterval) -> WatchProductionStoragePolicy.Item {
        WatchProductionStoragePolicy.Item(
            paragraphID: id,
            byteCount: bytes,
            lastQueuedAt: Date(timeIntervalSince1970: 1_700_000_000 - ageSeconds)
        )
    }

    @Test func defaultCapIs200MB() {
        #expect(WatchProductionStoragePolicy.maxProductionBytes == 200 * 1024 * 1024)
    }

    @Test func evictsOldestFirstWhenOverCap() {
        let policy = WatchProductionStoragePolicy()
        let oldest = UUID()
        let newest = UUID()
        let items = [
            item(oldest, bytes: 150 * 1024 * 1024, ageSeconds: 100),
            item(newest, bytes: 100 * 1024 * 1024, ageSeconds: 10)
        ]
        let candidates = policy.evictionCandidates(items: items, cap: 160 * 1024 * 1024)
        #expect(candidates == [oldest])
    }

    @Test func keepsProtectedParagraphs() {
        let policy = WatchProductionStoragePolicy()
        let current = UUID()
        let items = [
            item(current, bytes: 150 * 1024 * 1024, ageSeconds: 100),
            item(UUID(), bytes: 100 * 1024 * 1024, ageSeconds: 10)
        ]
        let candidates = policy.evictionCandidates(items: items, cap: 120 * 1024 * 1024, keep: [current])
        #expect(!candidates.contains(current))
        #expect(candidates.count == 1)
    }

    @Test func noEvictionWhenUnderCap() {
        let policy = WatchProductionStoragePolicy()
        let items = [item(UUID(), bytes: 10 * 1024 * 1024, ageSeconds: 10)]
        #expect(policy.evictionCandidates(items: items, cap: 200 * 1024 * 1024).isEmpty)
    }
}
