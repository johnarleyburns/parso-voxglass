import Foundation
@preconcurrency import WatchConnectivity
import VoxglassWatchProtocol

@MainActor
final class WatchSessionAdapter: NSObject, ObservableObject {
    static let shared = WatchSessionAdapter()
    @Published private(set) var isReachable = false
    @Published private(set) var snapshot: WatchLibrarySnapshot?
    @Published private(set) var connectionError: String?
    @Published private(set) var requestedDownloadBookID: WatchBookID?
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
        else {
            apply(WCSession.default.applicationContext)
            requestProjection()
        }
    }

    func requestDownload(for book: WatchBookDTO) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            connectionError = "The iPhone connection is not active."
            return
        }
        let manifest = WatchManifest(
            bookID: book.id,
            revision: snapshot?.revision ?? 0,
            requiredChapterIDs: book.chapters.map(\.id)
        )
        guard let data = try? WatchProtocolEnvelope.encode(
            kind: .setBookDownload,
            payload: manifest,
            libraryID: snapshot?.pairedLibraryID ?? .unknown,
            revision: snapshot?.revision ?? 0
        ) else { return }
        WCSession.default.transferUserInfo(WatchProtocolEnvelope.dictionary(for: data))
    }

    func reportDownload(book: WatchBookDTO, bytes: Int64, complete: Bool) {
        let acknowledgement = WatchManifestAcknowledgement(
            bookID: book.id,
            revision: snapshot?.revision ?? 0,
            complete: complete,
            installedBytes: bytes
        )
        guard let data = try? WatchProtocolEnvelope.encode(
            kind: .watchManifest,
            payload: acknowledgement,
            libraryID: snapshot?.pairedLibraryID ?? .unknown,
            revision: snapshot?.revision ?? 0
        ) else { return }
        WCSession.default.transferUserInfo(WatchProtocolEnvelope.dictionary(for: data))
    }

    private func requestProjection() {
        guard WCSession.default.activationState == .activated else { return }
        isReachable = WCSession.default.isReachable
        guard isReachable else { return }
        let hello = WatchHello(
            pairedLibraryID: snapshot?.pairedLibraryID ?? .unknown,
            lastAppliedRevision: snapshot?.revision ?? 0
        )
        guard let data = try? WatchProtocolEnvelope.encode(
            kind: .hello,
            payload: hello,
            libraryID: snapshot?.pairedLibraryID ?? .unknown,
            revision: snapshot?.revision ?? 0
        ) else { return }
        WCSession.default.sendMessage(
            WatchProtocolEnvelope.dictionary(for: data),
            replyHandler: { [weak self] reply in
                Task { @MainActor in self?.apply(reply) }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in self?.connectionError = error.localizedDescription }
            }
        )
    }

    private func apply(_ dictionary: [String: Any]) {
        guard let data = WatchProtocolEnvelope.payloadData(in: dictionary),
              let envelope = try? WatchProtocolEnvelope.decode(data) else { return }
        switch envelope.kind {
        case .librarySnapshot:
            guard let value = try? envelope.decodePayload(WatchLibrarySnapshot.self) else { return }
            if snapshot == nil || value.revision >= (snapshot?.revision ?? 0) {
                snapshot = value
                connectionError = nil
            }
        case .bookManifest:
            guard let manifest = try? envelope.decodePayload(WatchManifest.self) else { return }
            requestedDownloadBookID = manifest.bookID
        case .removeBookDownload:
            guard let manifest = try? envelope.decodePayload(WatchManifest.self) else { return }
            requestedDownloadBookID = nil
            NotificationCenter.default.post(
                name: .watchRemoveDownloadedBook,
                object: manifest.bookID.rawValue
            )
        default:
            break
        }
    }

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
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isReachable = activationState == .activated && reachable
            self.connectionError = message
            self.refresh()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let context = WatchUncheckedBox(applicationContext)
        Task { @MainActor in self.apply(context.value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        let payload = WatchUncheckedBox(userInfo)
        Task { @MainActor in self.apply(payload.value) }
    }
}

extension Notification.Name {
    static let watchRemoveDownloadedBook = Notification.Name("watchRemoveDownloadedBook")
}

private struct WatchUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
