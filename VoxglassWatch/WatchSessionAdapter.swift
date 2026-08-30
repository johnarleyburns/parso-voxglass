import Foundation
@preconcurrency import WatchConnectivity
import VoxglassWatchProtocol

@MainActor
final class WatchSessionAdapter: NSObject, ObservableObject {
    static let shared = WatchSessionAdapter()
    @Published private(set) var isReachable = false
    @Published private(set) var snapshot: WatchLibrarySnapshot?
    private let smoke = ProcessInfo.processInfo.arguments.contains("-uiTestSeed") || ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_ALICE"] == "1"

    override init() {
        super.init()
        guard WCSession.isSupported() else { seedSmoke(); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        seedSmoke()
    }

    func refresh() {
        if smoke { seedSmoke() }
        else if let data = WCSession.default.applicationContext[WatchProtocolEnvelope.payloadKey] as? Data,
                let envelope = try? WatchProtocolEnvelope.decode(data),
                envelope.kind == .librarySnapshot,
                let value = try? envelope.decodePayload(WatchLibrarySnapshot.self) { snapshot = value }
    }

    func requestDownload(for book: WatchBookDTO) { }

    private func seedSmoke() {
        guard smoke else { return }
        let aliceID = WatchBookID("alice")
        let catchID = WatchBookID("catch-22")
        func chapters(_ prefix: String) -> [WatchChapterDTO] {
            (1...3).map { WatchChapterDTO(id: WatchChapterID("\(prefix)-\($0)"), index: $0 - 1, title: "Chapter \($0)", duration: 640, approvedStreamURL: URL(string: "https://archive.org/download/example/ch\($0).mp3")) }
        }
        snapshot = WatchLibrarySnapshot(pairedLibraryID: WatchPairedLibraryID("smoke"), revision: 1, books: [
            WatchBookDTO(id: aliceID, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll", artworkKey: "alice", metadataRevision: 1, chapters: chapters("alice")),
            WatchBookDTO(id: catchID, title: "Catch-22", author: "Joseph Heller", artworkKey: "catch-22", metadataRevision: 1, chapters: chapters("catch"))
        ])
        isReachable = true
    }
}

extension WatchSessionAdapter: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) { Task { @MainActor in self.refresh() } }
}
