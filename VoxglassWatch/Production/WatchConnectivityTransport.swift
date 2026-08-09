import Foundation
@preconcurrency import WatchConnectivity
import VoxglassCore
import Observation

public enum WatchLinkTransportError: Error, LocalizedError, Equatable {
    case notActivated
    case unsupported
    case phoneUnreachable

    public var errorDescription: String? {
        switch self {
        case .notActivated:
            "The iPhone connection is still starting."
        case .unsupported:
            "WatchConnectivity is not available."
        case .phoneUnreachable:
            "iPhone not reachable. Your review actions are saved and will sync."
        }
    }
}

/// Watch-side concrete `WatchTransport` over `WCSession`. Receives summaries and
/// review queues pushed down from the phone, transfers review events up to the phone,
/// and asks the phone to refresh. The watch never initializes CloudKit (gate G-5).
@MainActor
@Observable
public final class WatchConnectivityTransport: NSObject, @preconcurrency WatchTransport, WCSessionDelegate {

    private let session: WCSession
    private(set) public var isReachable = false
    private(set) public var activationState: WatchLinkState = .notActivated

    private(set) public var summaries: [ProjectSummary] = []
    private(set) public var activeQueue: ResolvedQueuePayload?
    private(set) public var recordingRemoteStatus: RecordingRemoteStatus?

    public var onSummariesChanged: (([ProjectSummary]) -> Void)?
    public var onActiveQueueChanged: ((ResolvedQueuePayload) -> Void)?
    public var onReachabilityChanged: ((Bool) -> Void)?
    public var onAudioFileReceived: ((UUID, URL) -> Void)?
    public var onRecordingRemoteStatusChanged: ((RecordingRemoteStatus) -> Void)?

    private var statusContinuations: [AsyncStream<RecordingRemoteStatus>.Continuation] = []

    public override init() {
        session = WCSession.default
        super.init()
        session.delegate = self
        session.activate()
    }

    // MARK: WatchTransport (watch side = receiving + event upload)

    public func sendSummaries(_ incoming: [ProjectSummary]) async throws {
        summaries = incoming
        onSummariesChanged?(incoming)
    }

    public func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws {
        activeQueue = payload
        onActiveQueueChanged?(payload)
    }

    public func sendAudio(_ items: [WatchAudioItem]) async throws {
        // Paragraph audio arrives as transferFile payloads handled in the delegate;
        // this is a fallback for non-file transports.
    }

    public func sendArtwork(_ incoming: [UUID: Data]) async throws {
        // Artwork arrives as transferFile payloads handled in the delegate.
    }

    public func sendEvents(_ events: [ReviewEvent]) async throws {
        guard WCSession.isSupported() else { throw WatchLinkTransportError.unsupported }
        guard session.activationState == .activated else { throw WatchLinkTransportError.notActivated }
        for event in events {
            let userInfo = try WatchPhoneMessageCodec.message(
                action: ProductionTransportAction.reviewEvent,
                payload: event
            )
            session.transferUserInfo(userInfo)
        }
    }

    public func receiveEvents() -> AsyncStream<ReviewEvent> {
        AsyncStream { _ in }
    }

    public func requestRefresh() async throws {
        guard WCSession.isSupported() else { throw WatchLinkTransportError.unsupported }
        guard session.activationState == .activated else { throw WatchLinkTransportError.notActivated }

        let message = WatchPhoneMessageCodec.message(action: ProductionTransportAction.requestRefresh)
        if session.isReachable {
            try await withCheckedThrowingContinuation { continuation in
                session.sendMessage(
                    message,
                    replyHandler: { _ in continuation.resume() },
                    errorHandler: { continuation.resume(throwing: $0) }
                )
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    // MARK: Recording remote (§14.3)

    public func sendRecordingRemoteCommand(_ command: RecordingRemoteCommand) async throws {
        guard WCSession.isSupported() else { throw WatchLinkTransportError.unsupported }
        guard session.activationState == .activated else { throw WatchLinkTransportError.notActivated }
        let message = try WatchPhoneMessageCodec.message(
            action: ProductionTransportAction.recordingRemoteCommand,
            payload: command
        )
        // sendMessage when reachable (live feedback); transferUserInfo when not,
        // so a queued command is still delivered once the phone catches up. The
        // phone dedupes by (sessionID, sequence), so the retry can never act twice.
        if session.isReachable {
            try await withCheckedThrowingContinuation { continuation in
                session.sendMessage(
                    message,
                    replyHandler: { _ in continuation.resume() },
                    errorHandler: { continuation.resume(throwing: $0) }
                )
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    public func sendRecordingRemoteStatus(_ status: RecordingRemoteStatus) async throws {
        recordingRemoteStatus = status
        onRecordingRemoteStatusChanged?(status)
        for continuation in statusContinuations {
            continuation.yield(status)
        }
    }

    public func receiveRecordingRemoteStatus() -> AsyncStream<RecordingRemoteStatus> {
        AsyncStream { continuation in
            statusContinuations.append(continuation)
        }
    }

    // MARK: WCSessionDelegate

    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        let context = UncheckedSendable(value: session.receivedApplicationContext)
        Task { @MainActor in
            self.activationState = activationState == .activated ? .activated : .notActivated
            self.isReachable = reachable
            self.onReachabilityChanged?(reachable)
            self.ingestApplicationContext(context.value)
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.onReachabilityChanged?(reachable)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let context = UncheckedSendable(value: applicationContext)
        Task { @MainActor in self.ingestApplicationContext(context.value) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        let userInfo = UncheckedSendable(value: userInfo)
        Task { @MainActor in self.ingestMessage(userInfo.value) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        let message = UncheckedSendable(value: message)
        Task { @MainActor in self.ingestMessage(message.value) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let message = UncheckedSendable(value: message)
        let replyHandler = UncheckedSendable(value: replyHandler)
        Task { @MainActor in
            self.ingestMessage(message.value)
            replyHandler.value(["received": true])
        }
    }

    nonisolated public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let file = UncheckedSendable(value: file)
        Task { @MainActor in self.ingest(file: file.value) }
    }

    // MARK: Ingest

    private func ingestApplicationContext(_ context: [String: Any]) {
        guard let action = WatchPhoneMessageCodec.action(from: context) else { return }
        switch action {
        case ProductionTransportAction.sendSummaries:
            if let value = try? WatchPhoneMessageCodec.payload([ProjectSummary].self, from: context) {
                Task { try? await sendSummaries(value) }
            }
        case ProductionTransportAction.sendActiveQueue:
            if let value = try? WatchPhoneMessageCodec.payload(ResolvedQueuePayload.self, from: context) {
                Task { try? await sendActiveQueue(value) }
            }
        case ProductionTransportAction.recordingRemoteStatus:
            if let value = try? WatchPhoneMessageCodec.payload(RecordingRemoteStatus.self, from: context) {
                Task { try? await sendRecordingRemoteStatus(value) }
            }
        default:
            break
        }
    }

    private func ingestMessage(_ message: [String: Any]) {
        guard let action = WatchPhoneMessageCodec.action(from: message) else { return }
        switch action {
        case ProductionTransportAction.sendSummaries:
            if let value = try? WatchPhoneMessageCodec.payload([ProjectSummary].self, from: message) {
                Task { try? await sendSummaries(value) }
            }
        case ProductionTransportAction.sendActiveQueue:
            if let value = try? WatchPhoneMessageCodec.payload(ResolvedQueuePayload.self, from: message) {
                Task { try? await sendActiveQueue(value) }
            }
        case ProductionTransportAction.recordingRemoteStatus:
            if let value = try? WatchPhoneMessageCodec.payload(RecordingRemoteStatus.self, from: message) {
                Task { try? await sendRecordingRemoteStatus(value) }
            }
        default:
            break
        }
    }

    private func ingest(file: WCSessionFile) {
        guard let metadata = file.metadata,
              let action = WatchPhoneMessageCodec.action(from: metadata),
              action == ProductionTransportAction.sendAudio,
              let rawID = metadata["paragraphID"] as? String,
              let paragraphID = UUID(uuidString: rawID) else { return }
        onAudioFileReceived?(paragraphID, file.fileURL)
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
