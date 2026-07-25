import Foundation
import WatchConnectivity
import VoxglassCore

@MainActor
final class PhoneAudioRelay: NSObject, ObservableObject {
    static let shared = PhoneAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false

    private let session: WCSession

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

    func transferChapterFile(at url: URL, chapterKey: String) {
        session.transferFile(url, metadata: ["chapterKey": chapterKey])
    }
}

extension PhoneAudioRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            isWatchAppInstalled = session.isWatchAppInstalled
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handleReceivedMessage(message, replyHandler: replyHandler)
        }
    }

    private func handleReceivedMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let action = message["action"] as? String else {
            replyHandler(["received": true])
            return
        }
        switch action {
        case "requestChapterFile":
            let contentKey = message["contentKey"] as? String ?? ""
            let chapterKey = message["chapterKey"] as? String ?? ""
            Task {
                let found = await findAndSendChapter(contentKey: contentKey, chapterKey: chapterKey)
                replyHandler(["found": found])
            }
            return
        default:
            break
        }
        replyHandler(["received": true])
    }

    private func findAndSendChapter(contentKey: String, chapterKey: String) async -> Bool {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voxglass-cache")
        let fileURL = cacheDir.appendingPathComponent(chapterKey)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        transferChapterFile(at: fileURL, chapterKey: chapterKey)
        return true
    }
}
