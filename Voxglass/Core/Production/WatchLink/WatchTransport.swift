import Foundation

/// Activation/reachability state of the phone↔watch relay, as seen from one side.
public enum WatchLinkState: String, Codable, Sendable, Equatable {
    case notActivated
    case activated
    case reachable
}

/// The single protocol the watch speaks to the phone and the phone speaks to the
/// watch. The watch never touches CloudKit; it only ever talks through this
/// abstraction (concrete: `WatchConnectivityTransport` on each side, fake:
/// `FakeWatchTransport` in test support).
///
/// Direction is encoded by which side calls the method:
/// - The **phone** calls `sendSummaries`/`sendActiveQueue`/`sendAudio`/`sendArtwork`
///   to push state down to the watch.
/// - The **watch** calls `requestRefresh` to ask the phone to re-push, and delivers
///   review actions through `sendEvents` (guaranteed-delivery transfer, FIFO).
/// - `receiveEvents` surfaces review actions on the side that consumes them (the
///   phone, which folds them into CloudKit; the watch keeps an empty stream).
public protocol WatchTransport: Sendable {
    var isReachable: Bool { get }
    var activationState: WatchLinkState { get }

    func sendSummaries(_ summaries: [ProjectSummary]) async throws
    func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws
    func sendAudio(_ items: [WatchAudioItem]) async throws
    func sendArtwork(_ artwork: [UUID: Data]) async throws
    func sendEvents(_ events: [ReviewEvent]) async throws
    func receiveEvents() -> AsyncStream<ReviewEvent>
    func requestRefresh() async throws
}
