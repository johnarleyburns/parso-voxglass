import Foundation
import VoxglassCore

/// Provisional phone-side production data source for CarPlay. S5 wires it to the
/// CloudKit projection preview store; until then it serves the local projection
/// cache (empty by default), so the production tab bar renders its empty states
/// without touching iCloud.
public final class LocalCarPlayProductionProvider: CarPlayProductionDataProviding {

    public static let shared = LocalCarPlayProductionProvider()

    private let summaries: [ProjectSummary]
    private let queues: [ProductionQueueType: ResolvedQueuePayload]

    public init(
        summaries: [ProjectSummary] = [],
        queues: [ProductionQueueType: ResolvedQueuePayload] = [:]
    ) {
        self.summaries = summaries
        self.queues = queues
    }

    public func productionSummaries() -> [ProjectSummary] {
        summaries
    }

    public func queuePayload(_ type: ProductionQueueType) -> ResolvedQueuePayload? {
        queues[type]
    }
}

/// CarPlay review events land in the phone's own outbox (CarPlay runs inside the
/// phone process), persisted exactly like watch events and flushed to CloudKit by
/// the S5 sync engine. Reuses `WatchReviewOutbox` + `FileWatchOutboxStorage`.
public final class PhoneProductionEventSink: CarPlayEventDelivering {

    private let outbox: WatchReviewOutbox

    public init(directory: URL? = nil) {
        self.outbox = WatchReviewOutbox(
            storage: FileWatchOutboxStorage(directory: directory ?? PhoneProductionEventSink.defaultOutboxDirectory)
        )
    }

    public func send(_ events: [ReviewEvent]) throws {
        for event in events {
            try outbox.enqueue(event)
        }
    }

    private static var defaultOutboxDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("ProductionOutbox", isDirectory: true)
    }
}

/// Plays one paragraph's audio in the car. The concrete proxy player arrives with
/// S5 (projection proxies); this is a placeholder that satisfies the seam so the
/// CarPlay surface is fully wired and testable now.
public final class ProductionCarPlayPlayer: CarPlayProductionPlaying {

    public init() {}

    public func play(paragraphID: UUID, in payload: ResolvedQueuePayload) async {
        // S5: resolve the proxy asset from the preview store and hand it to the
        // shared playback engine with AVAudioSession configured for CarPlay.
    }

    public func pause() async {}
}
