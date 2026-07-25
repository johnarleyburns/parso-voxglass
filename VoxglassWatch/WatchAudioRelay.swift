import Foundation
import WatchConnectivity
import VoxglassCore

@MainActor
final class WatchAudioRelay: NSObject, ObservableObject {
    static let shared = WatchAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isCompanionAppInstalled: Bool = false

    private let session: WCSession
    var onFileReceived: ((URL, String) -> Void)?

    override init() {
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

    func requestChapter(_ contentKey: String, chapterKey: String) {
        let message: [String: Any] = [
            "action": "requestChapterFile",
            "contentKey": contentKey,
            "chapterKey": chapterKey
        ]
        session.sendMessage(message, replyHandler: nil)
    }
}

extension WatchAudioRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            isCompanionAppInstalled = session.isCompanionAppInstalled
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            handleReceivedFile(file)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            handleReceivedMessage(message)
        }
    }

    nonisolated func session(
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
        let metadata = file.metadata
        let chapterKey = (metadata?["chapterKey"] as? String) ?? file.fileURL.lastPathComponent
        onFileReceived?(file.fileURL, chapterKey)
    }

    private func handleReceivedMessage(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        switch action {
        case "transferComplete":
            break
        case "transferFailed":
            break
        default:
            break
        }
    }
}
