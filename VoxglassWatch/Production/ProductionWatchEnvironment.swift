import Foundation
import Observation
import VoxglassCore

/// App-level container for the watch's production preview + review relay. Holds the
/// transport, offline outbox, audio store, and player, and owns the current review
/// session. All view models are `@Observable` (gate G-3).
@MainActor
@Observable
public final class ProductionWatchEnvironment {

    public var summaries: [ProjectSummary] = []
    public var activeQueue: ResolvedQueuePayload?
    public var review: WatchReviewModel?
    public var pendingEventCount = 0
    public var lastSyncAt: Date?
    public var error: String?
    public var isReachable = false

    public let transport: any WatchTransport
    public let outbox: WatchReviewOutbox
    public let audioStore: WatchProductionAudioStore
    public let player: WatchSegmentPlayer

    public init(
        transport: any WatchTransport,
        outbox: WatchReviewOutbox,
        audioStore: WatchProductionAudioStore = WatchProductionAudioStore(),
        player: WatchSegmentPlayer = WatchSegmentPlayer()
    ) {
        self.transport = transport
        self.outbox = outbox
        self.audioStore = audioStore
        self.player = player
    }

    public static func make() -> ProductionWatchEnvironment {
        let transport = ProductionWatchSmoke.isEnabled
            ? ProductionWatchSmoke.makeTransport()
            : WatchConnectivityTransport()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let outboxDir = docs.appendingPathComponent("ProductionOutbox", isDirectory: true)
        return ProductionWatchEnvironment(
            transport: transport,
            outbox: WatchReviewOutbox(storage: FileWatchOutboxStorage(directory: outboxDir))
        )
    }

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        if let smoke = transport as? ProductionWatchSmoke.SmokeWatchTransport {
            summaries = smoke.seedSummaries
            activeQueue = smoke.seedQueue
            audioStore.preload(smoke.seedAudio)
        } else if let live = transport as? WatchConnectivityTransport {
            live.onSummariesChanged = { [weak self] value in self?.summaries = value }
            live.onActiveQueueChanged = { [weak self] value in self?.activeQueue = value }
            live.onReachabilityChanged = { [weak self] value in self?.isReachable = value }
            live.onAudioFileReceived = { [weak self] id, url in
                try? self?.audioStore.ingest(fileAt: url, for: id)
                self?.audioStore.evict()
            }
            summaries = live.summaries
            activeQueue = live.activeQueue
            do {
                try await live.requestRefresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
        isReachable = transport.isReachable
        await flushOutbox()
    }

    /// Starts a review session over the given queue payload.
    public func startReview(_ payload: ResolvedQueuePayload) {
        activeQueue = payload
        review = WatchReviewModel(payload: payload, environment: self)
    }

    /// Starts the flagged queue if one is available (the phone relays the current
    /// review queue; smoke seeds it directly).
    public func startFlaggedReview() {
        guard let queue = activeQueue else { return }
        startReview(queue)
    }

    /// Records a review action and tries to flush it to the phone immediately.
    public func sendEvent(_ event: ReviewEvent) async {
        do {
            try outbox.enqueue(event)
            await flushOutbox()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func flushOutbox() async {
        let pending = (try? outbox.pending().count) ?? 0
        guard pending > 0 else {
            pendingEventCount = 0
            return
        }
        guard transport.isReachable else {
            pendingEventCount = pending
            return
        }
        do {
            _ = try await outbox.flush(over: transport)
            lastSyncAt = Date()
            pendingEventCount = (try? outbox.pending().count) ?? 0
        } catch {
            pendingEventCount = pending
        }
    }

    public func refreshPendingCount() {
        pendingEventCount = (try? outbox.pending().count) ?? 0
    }

    private var didBootstrap = false
}
