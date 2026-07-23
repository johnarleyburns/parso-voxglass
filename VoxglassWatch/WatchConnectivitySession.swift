import Foundation
import WatchConnectivity
import VoxglassCore

/// Manages WatchConnectivity session for file transfers and state sync
/// between the watch app and iOS companion app.
@MainActor
public final class WatchConnectivitySession: NSObject, ObservableObject {
    public static let shared = WatchConnectivitySession()

    @Published public private(set) var isReachable: Bool = false
    @Published public private(set) var isCompanionAppInstalled: Bool = false
    @Published public private(set) var pendingTransfers: [WatchTransferRequest] = []

    private let session: WCSession

    public override init() {
        guard WCSession.isSupported() else {
            session = WCSession.default
            super.init()
            return
        }
        session = WCSession.default
        super.init()
        session.delegate = self
        session.activate()
    }

    /// Queues a file transfer request (phone must handle the actual transfer).
    public func requestTransfer(for bookID: UUID, chapterIDs: [UUID]) {
        let requestID = UUID()
        let request = WatchTransferRequest(
            id: requestID,
            bookID: bookID,
            chapterIDs: chapterIDs,
            createdAt: Date()
        )
        pendingTransfers.append(request)

        // Send request to phone
        let message: [String: Any] = [
            "action": "requestTransfer",
            "requestID": requestID.uuidString,
            "bookID": bookID.uuidString,
            "chapterIDs": chapterIDs.map(\.uuidString)
        ]
        session.sendMessage(message, replyHandler: nil) { error in
            // Phone unreachable — the UI shows waitingForPhone
        }
    }

    /// Cancels a pending transfer request.
    public func cancelTransfer(requestID: UUID) {
        pendingTransfers.removeAll { $0.id == requestID }
        let message: [String: Any] = [
            "action": "cancelTransfer",
            "requestID": requestID.uuidString
        ]
        session.sendMessage(message, replyHandler: nil)
    }
}

extension WatchConnectivitySession: WCSessionDelegate {
    public nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            isCompanionAppInstalled = session.isCompanionAppInstalled
        }
    }

    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    public nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            // Handle received file from phone
            handleReceivedFile(file)
        }
    }

    public nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            handleReceivedMessage(message)
        }
    }

    public nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handleReceivedMessage(message)
            replyHandler(["received": true])
        }
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        // Store received audio file in watch cache
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voxglass-watch-transfers")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let dest = cacheDir.appendingPathComponent(file.fileURL.lastPathComponent)
        try? FileManager.default.moveItem(at: file.fileURL, to: dest)
    }

    private func handleReceivedMessage(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }

        switch action {
        case "transferStarted":
            if let requestID = message["requestID"] as? String,
               let uuid = UUID(uuidString: requestID) {
                // Transfer has begun
            }
        case "transferComplete":
            if let requestID = message["requestID"] as? String,
               let uuid = UUID(uuidString: requestID) {
                pendingTransfers.removeAll { $0.id == uuid }
            }
        case "transferFailed":
            if let requestID = message["requestID"] as? String,
               let uuid = UUID(uuidString: requestID) {
                // Mark as failed
            }
        default:
            break
        }
    }
}

public struct WatchTransferRequest: Identifiable, Equatable {
    public let id: UUID
    public let bookID: UUID
    public let chapterIDs: [UUID]
    public let createdAt: Date
}
