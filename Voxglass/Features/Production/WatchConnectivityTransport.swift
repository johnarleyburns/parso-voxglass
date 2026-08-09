import Foundation
import WatchConnectivity
import VoxglassCore
import Observation

/// Phone-side concrete `WatchTransport` over `WCSession` (spec §18.2.8). Pushes
/// production summaries and the active review queue to the watch as application
/// context, transfers proxy audio and artwork as queued file transfers, and hands
/// decoded review events to `onEventReceived` so the phone can enqueue them for the
/// iPhone — offline watch actions reach the iPhone exactly once (§13.7).
///
/// `WCSession` permits a single delegate, which the consumer relay
/// (`PhoneAudioRelay`) owns, so this transport does not register a delegate of its
/// own. Incoming production messages are forwarded here by that relay. The watch
/// never initializes CloudKit (gate G-5); it speaks only through this seam.
@MainActor
@Observable
public final class WatchConnectivityTransport: WatchTransport {

    public private(set) var isReachable = false
    public private(set) var activationState: WatchLinkState = .notActivated

    /// Decoded review events the watch sent. The phone enqueues these into its
    /// outbox so they are pushed to the iPhone exactly once.
    public var onEventReceived: ((ReviewEvent) -> Void)?

    /// Called when the shared `WCSession` reports a reachability change.
    public var onReachabilityChanged: ((Bool) -> Void)?

    private let session: WCSession
    private var currentSummaries: [ProjectSummary] = []
    private var currentQueue: ResolvedQueuePayload?
    private var eventContinuations: [AsyncStream<ReviewEvent>.Continuation] = []

    public init(session: WCSession = .default) {
        self.session = session
    }

    // MARK: - WatchTransport (phone side = pushing state down to the watch)

    public func sendSummaries(_ summaries: [ProjectSummary]) async throws {
        currentSummaries = summaries
        try pushContext(action: ProductionTransportAction.sendSummaries, payload: summaries)
    }

    public func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws {
        currentQueue = payload
        try pushContext(action: ProductionTransportAction.sendActiveQueue, payload: payload)
    }

    public func sendAudio(_ items: [WatchAudioItem]) async throws {
        guard isSessionUsable else { return }
        for item in items {
            guard let url = item.fileURL else { continue }
            session.transferFile(url, metadata: [
                WatchPhoneMessageCodec.actionKey: ProductionTransportAction.sendAudio,
                "paragraphID": item.paragraphID.uuidString,
                "sha256": item.sha256,
                "byteCount": item.byteCount
            ])
        }
    }

    public func sendArtwork(_ artwork: [UUID: Data]) async throws {
        guard isSessionUsable else { return }
        let fileManager = FileManager.default
        for (projectID, data) in artwork {
            let url = fileManager.temporaryDirectory
                .appendingPathComponent("watch-artwork-\(projectID.uuidString).jpg")
            try data.write(to: url, options: .atomic)
            session.transferFile(url, metadata: [
                WatchPhoneMessageCodec.actionKey: ProductionTransportAction.sendArtwork,
                "projectID": projectID.uuidString
            ])
        }
    }

    public func sendEvents(_ events: [ReviewEvent]) async throws {
        // The phone never emits review events to the watch; the watch creates them.
    }

    public func receiveEvents() -> AsyncStream<ReviewEvent> {
        AsyncStream { continuation in
            eventContinuations.append(continuation)
        }
    }

    /// The watch asked the phone to re-push. The phone owns the latest projection
    /// state, so it simply replays what it last sent.
    public func requestRefresh() async throws {
        if !currentSummaries.isEmpty {
            try await sendSummaries(currentSummaries)
        }
        if let queue = currentQueue {
            try await sendActiveQueue(queue)
        }
    }

    // MARK: - Incoming (called by PhoneAudioRelay's WCSession delegate)

    /// Routes an incoming production message (delivered as userInfo, message, or
    /// application context) that the app relay forwarded.
    public func handleIncoming(_ message: [String: Any]) {
        guard let action = WatchPhoneMessageCodec.action(from: message) else { return }
        switch action {
        case ProductionTransportAction.reviewEvent:
            guard let event = try? WatchPhoneMessageCodec.payload(ReviewEvent.self, from: message) else { return }
            onEventReceived?(event)
            for continuation in eventContinuations {
                continuation.yield(event)
            }
        case ProductionTransportAction.requestRefresh:
            Task { try? await requestRefresh() }
        default:
            break
        }
    }

    /// Updates reachability when the shared `WCSession` reports a change.
    public func updateReachability(reachable: Bool, activated: Bool) {
        isReachable = reachable
        activationState = activated ? .activated : .notActivated
        onReachabilityChanged?(reachable)
    }

    // MARK: - Internals

    private var isSessionUsable: Bool {
        WCSession.isSupported() && session.activationState == .activated
    }

    private func pushContext<Payload: Encodable>(action: String, payload: Payload) throws {
        guard isSessionUsable else { return }
        let context = try WatchPhoneMessageCodec.message(action: action, payload: payload)
        try session.updateApplicationContext(context)
    }
}
