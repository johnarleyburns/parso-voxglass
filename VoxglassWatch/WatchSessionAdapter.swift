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
    /// Set once a book pushed from the phone (`PhoneAudioRelay.transferBookToWatch`)
    /// has had every one of its chapter files received over `WCSession`
    /// file-transfer. `WatchAppServices` observes this the same way it already
    /// observes `requestedDownloadBookID`.
    @Published private(set) var completedFileTransfer: (bookID: WatchBookID, bytes: Int64)?
    /// Per-book count of chapter files received so far via `didReceive file:`,
    /// keyed against the `totalChapterCount` each file's metadata carries.
    /// In-memory only: if the app is killed mid-transfer, re-tapping "Send to
    /// Watch" on the phone resends everything, which is an acceptable retry
    /// story for this feature.
    private var receivedChapterFiles: [WatchBookID: (count: Int, bytes: Int64)] = [:]
    /// `WCSession.isReachable` can toggle rapidly and spuriously — observed
    /// live flapping the connection indicator and the visible book list
    /// (`WatchAppServices.visibleBooks` depends on it) back and forth, jarring
    /// during an active file transfer in particular. Only commit a change
    /// once it's held for a short settle window instead of reacting to every
    /// raw toggle.
    private var reachabilityDebounce: Task<Void, Never>?
    private let smoke = ProcessInfo.processInfo.arguments.contains("-uiTestSeed") || ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_ALICE"] == "1"
    /// `snapshot` used to be in-memory only — populated exclusively by a live
    /// WCSession message/context delivery. That meant a book already
    /// downloaded to the watch (its bytes on disk, its id in
    /// `WatchAppServices.downloaded`) still couldn't be *shown* while
    /// disconnected, because there was no title/author/chapter metadata for
    /// it until the next live connection. Persist the last snapshot so it
    /// survives a relaunch or a stretch with no iPhone in range.
    private static let snapshotDefaultsKey = "watch.librarySnapshot"

    override init() {
        super.init()
        snapshot = Self.loadPersistedSnapshot()
        guard WCSession.isSupported() else { seedSmoke(); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        seedSmoke()
    }

    private static func loadPersistedSnapshot() -> WatchLibrarySnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(WatchLibrarySnapshot.self, from: data)
    }

    private func persistSnapshot() {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.snapshotDefaultsKey)
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
            guard var value = try? envelope.decodePayload(WatchLibrarySnapshot.self) else { return }
            if snapshot == nil || value.revision >= (snapshot?.revision ?? 0) {
                // Belt-and-braces: de-duplicate by book id so a duplicate
                // record on the phone side (or a re-sent/merged snapshot)
                // never renders the same book twice in the watch's list.
                var seen = Set<WatchBookID>()
                value.books = value.books.filter { seen.insert($0.id).inserted }
                snapshot = value
                connectionError = nil
                persistSnapshot()
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

    /// Called after a chapter file has already been copied into its final
    /// `DownloadedBooks/<bookID>/<filename>` location. Tracks arrival count
    /// per book and publishes completion once every expected chapter is in.
    private func recordReceivedChapterFile(bookID: WatchBookID, totalChapterCount: Int, bytes: Int64) {
        var entry = receivedChapterFiles[bookID] ?? (count: 0, bytes: 0)
        entry.count += 1
        entry.bytes += bytes
        guard entry.count < totalChapterCount else {
            receivedChapterFiles.removeValue(forKey: bookID)
            completedFileTransfer = (bookID, entry.bytes)
            return
        }
        receivedChapterFiles[bookID] = entry
    }

    private func debounceReachabilityChange() {
        reachabilityDebounce?.cancel()
        reachabilityDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            // Re-read the live value rather than trusting what triggered this
            // call — if it flipped again during the settle window, this task
            // was already cancelled and superseded by a fresh one.
            self.isReachable = WCSession.default.isReachable
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
        Task { @MainActor in self.debounceReachabilityChange() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let context = WatchUncheckedBox(applicationContext)
        Task { @MainActor in self.apply(context.value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        let payload = WatchUncheckedBox(userInfo)
        Task { @MainActor in self.apply(payload.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        let payload = WatchUncheckedBox(message)
        Task { @MainActor in self.apply(payload.value) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        let payload = WatchUncheckedBox(message)
        let reply = WatchUncheckedBox(replyHandler)
        Task { @MainActor in
            self.apply(payload.value)
            reply.value(["received": true])
        }
    }

    /// `file.fileURL` and `file.metadata` are only valid synchronously during
    /// this call — WCSession deletes the underlying temp file once this
    /// method returns — so the copy into durable storage happens right here,
    /// not after hopping to the main actor. Files lacking the phone-push
    /// metadata this expects (e.g. the just-in-time single-chapter reply
    /// path, or the separate manifest-driven asset-file transfer) are
    /// silently ignored; they're handled elsewhere or not yet wired up.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata,
              let bookIDRaw = metadata["bookID"] as? String,
              let chapterFilename = metadata["chapterFilename"] as? String,
              let totalChapterCount = metadata["totalChapterCount"] as? Int else { return }
        let bookID = WatchBookID(bookIDRaw)
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("DownloadedBooks/\(bookID.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(chapterFilename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor in
                self.recordReceivedChapterFile(bookID: bookID, totalChapterCount: totalChapterCount, bytes: bytes)
            }
        } catch {
            return
        }
    }
}

extension Notification.Name {
    static let watchRemoveDownloadedBook = Notification.Name("watchRemoveDownloadedBook")
}

private struct WatchUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
