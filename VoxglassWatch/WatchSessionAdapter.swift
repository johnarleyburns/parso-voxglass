import Foundation
import AVFoundation
@preconcurrency import WatchConnectivity
import VoxglassWatchProtocol
import VoxglassWatchCore

/// Native messaging handles metadata; Apple file transfer handles only AAC audio and artwork.
@MainActor
final class WatchSessionAdapter: NSObject, ObservableObject {
    static let shared = WatchSessionAdapter()
    @Published private(set) var isReachable = false
    @Published private(set) var snapshot: WatchLibrarySnapshot?
    @Published private(set) var connectionError: String?
    @Published private(set) var phoneTransferProgress: [WatchBookID: (done: Int, total: Int)] = [:]
    @Published private(set) var bookReports: [WatchBookID: WatchManifestAcknowledgement] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var syncMessage: String?
    @Published private(set) var lastCatalogDate: Date?
    @Published private(set) var isReconciling = false
    @Published private(set) var audioReceipt = UserDefaults.standard.string(forKey: "watch.audioReceipt") ?? "No audio received yet."
    @Published private(set) var artworkReceipt = "No artwork received this session."
    @Published private(set) var reportMessage = "No watch report sent this session."
    private var reportGeneration = 0
    // Native file callbacks and MainActor removal/catalog callbacks share durable state.
    nonisolated private static let fileIO = NSLock()
    nonisolated private static func validateAAC(_ url: URL) throws {
        let audio = try AVAudioFile(forReading: url)
        guard audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              audio.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
    private var lastReceivedBookID: WatchBookID?
    private let smoke = ProcessInfo.processInfo.arguments.contains("-uiTestSeed")
        || ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_ALICE"] == "1"
    private static let snapshotKey = "watch.librarySnapshot"
    static let resetKey = "watch.listeningResetPending"
    private static var audioRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadedBooks", isDirectory: true)
    }

    override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.resetKey) {
            // A confirmed reset applies before opening the listening state. Narration outboxes
            // are deliberately excluded: unsubmitted review events must never be erased.
            do {
                let root = Self.audioRoot
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                for name in ["watch-playback-positions.json", "watch-playback-speeds.json"] {
                    let url = root.deletingLastPathComponent().appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
                for key in [Self.snapshotKey, "watch.downloaded", "watch.listened", "watch.audioReceipt", "watch.removedBookIDs", "watch.bookRevisions", Self.resetKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                WatchContinueListeningStore.save(nil)
                audioReceipt = "No audio received yet."
            } catch { connectionError = "Reset failed: \(error.localizedDescription)" }
        }
        if let data = UserDefaults.standard.data(forKey: Self.snapshotKey) {
            snapshot = try? JSONDecoder().decode(WatchLibrarySnapshot.self, from: data)
        }
        if smoke { seedSmoke(); return }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        reconcileFiles(forceReport: true)
    }

    /// Refresh local diagnostics and consume the phone's latest retained context, never request it.
    func refresh() {
        guard !smoke, WCSession.isSupported() else { return }
        isReachable = WCSession.default.activationState == .activated && WCSession.default.isReachable
        apply(WCSession.default.receivedApplicationContext)
        reconcileFiles(forceReport: true)
    }

    /// The sole watch-initiated sync request is live-only, matching Cladiron's settings sync.
    func syncNow() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            isReachable = false
            syncMessage = "Sync Now available when connected to iPhone."
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = "Sync sent."
        guard let data = try? WatchProtocolEnvelope.encode(kind: .reconcileRequest,
            payload: [String: String](), libraryID: snapshot?.pairedLibraryID ?? .unknown) else {
            isSyncing = false
            return
        }
        WCSession.default.sendMessage(WatchProtocolEnvelope.dictionary(for: data), replyHandler: { _ in },
            errorHandler: { [weak self] error in
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.isSyncing = false
                    self?.syncMessage = message
                }
            })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, isSyncing else { return }
            isSyncing = false
            syncMessage = "Sync sent. No updated iPhone catalog received yet."
        }
    }

    private func apply(_ dictionary: [String: Any]) {
        // Never block the UI behind a large native file copy/checksum. Defer this
        // already-received local value; this sends no request and retries no audio.
        guard Self.fileIO.try() else {
            let box = WatchUncheckedBox(dictionary)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.apply(box.value)
            }
            return
        }
        defer { Self.fileIO.unlock() }
        guard let data = WatchProtocolEnvelope.payloadData(in: dictionary),
              let envelope = try? WatchProtocolEnvelope.decode(data) else { return }
        switch envelope.kind {
        case .librarySnapshot:
            // A retained pre-rewrite full-library projection is not this local-only catalog.
            guard envelope.version >= 2 else { return }
            guard var value = try? envelope.decodePayload(WatchLibrarySnapshot.self) else { return }
            if let current = snapshot, current.pairedLibraryID == value.pairedLibraryID,
               current.revision > value.revision { return }
            var seen = Set<WatchBookID>()
            value.books = value.books.filter { seen.insert($0.id).inserted }
            let needsScan = WatchPhonePushFiles.needsReconciliation(previous: snapshot, next: value)
            snapshot = value
            lastCatalogDate = envelope.sentAt
            isSyncing = false
            syncMessage = "Sync updated."
            connectionError = nil
            if let saved = try? JSONEncoder().encode(value) { UserDefaults.standard.set(saved, forKey: Self.snapshotKey) }
            var removed = Set(UserDefaults.standard.stringArray(forKey: "watch.removedBookIDs") ?? [])
            var revisions = UserDefaults.standard.dictionary(forKey: "watch.bookRevisions") ?? [:]
            for book in value.books {
                let latest = revisions[book.id.rawValue] as? Int64 ?? 0
                if book.metadataRevision > latest, value.downloadStates?[book.id] != .removing {
                    removed.remove(book.id.rawValue)
                }
                revisions[book.id.rawValue] = max(latest, book.metadataRevision)
            }
            UserDefaults.standard.set(revisions, forKey: "watch.bookRevisions")
            UserDefaults.standard.set(Array(removed), forKey: "watch.removedBookIDs")
            if needsScan { reconcileFiles(forceReport: true) }
            else if !isReconciling { publishCurrentReports() }
        case .removeBookDownload:
            guard let manifest = try? envelope.decodePayload(WatchManifest.self),
                  WatchPhonePushFiles.safeComponent(manifest.bookID.rawValue) else { return }
            var revisions = UserDefaults.standard.dictionary(forKey: "watch.bookRevisions") ?? [:]
            guard manifest.revision >= (revisions[manifest.bookID.rawValue] as? Int64 ?? 0) else { return }
            revisions[manifest.bookID.rawValue] = manifest.revision
            UserDefaults.standard.set(revisions, forKey: "watch.bookRevisions")
            var removed = Set(UserDefaults.standard.stringArray(forKey: "watch.removedBookIDs") ?? [])
            removed.insert(manifest.bookID.rawValue)
            UserDefaults.standard.set(Array(removed), forKey: "watch.removedBookIDs")
            let directory = Self.audioRoot.appendingPathComponent(manifest.bookID.rawValue, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                bookReports.removeValue(forKey: manifest.bookID)
                phoneTransferProgress.removeValue(forKey: manifest.bookID)
                snapshot?.books.removeAll { $0.id == manifest.bookID }
                if let snapshot, let saved = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(saved, forKey: Self.snapshotKey) }
                var removal = WatchManifestAcknowledgement(bookID: manifest.bookID, revision: manifest.revision,
                    complete: false, installedBytes: 0)
                removal.isRemoval = true
                report(removal, libraryID: envelope.pairedLibraryID)
                reconcileFiles()
            } catch { connectionError = "Removal failed: \(error.localizedDescription)" }
        case .reconcileRequest:
            reconcileFiles(forceReport: true)
        default: break
        }
    }

    private func reconcileFiles(forceReport: Bool = false) {
        guard !smoke, let snapshot else { return }
        reportGeneration += 1
        let generation = reportGeneration
        isReconciling = true
        let root = Self.audioRoot
        Task { [weak self] in
            let reports = await Task.detached {
                snapshot.books.map { WatchPhonePushFiles.report(book: $0, root: root) }
            }.value
            guard let self, generation == reportGeneration else { return }
            isReconciling = false
            let old = bookReports
            bookReports = Dictionary(uniqueKeysWithValues: reports.map { ($0.bookID, $0) })
            phoneTransferProgress = Dictionary(uniqueKeysWithValues: reports.filter { !$0.complete }.map { value in
                (value.bookID, (done: value.installedChapterIDs?.count ?? 0,
                    total: snapshot.books.first { $0.id == value.bookID }?.chapters.count ?? 0))
            })
            if forceReport || old != bookReports { publishCurrentReports() }
            if let id = lastReceivedBookID, bookReports[id]?.complete == true {
                audioReceipt = "Audio installed and ready to play."
                UserDefaults.standard.set(audioReceipt, forKey: "watch.audioReceipt")
            }
        }
    }

    /// Status reports are metadata, not requests. No fresh transfer is scheduled here.
    func publishCurrentReports() {
        guard !isReconciling else { return }
        let revision = Int64(UserDefaults.standard.integer(forKey: "watch.reportRevision")) + 1
        UserDefaults.standard.set(revision, forKey: "watch.reportRevision")
        guard let snapshot, WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? WatchProtocolEnvelope.encode(kind: .watchCatalog,
                payload: WatchDeviceCatalog(reports: bookReports.values.sorted { $0.bookID.rawValue < $1.bookID.rawValue }),
                libraryID: snapshot.pairedLibraryID, revision: revision) else { return }
        let message = WatchProtocolEnvelope.dictionary(for: data)
        // Native context coalesces periodic inventory reports; live delivery is only a fast path.
        do { try WCSession.default.updateApplicationContext(message) }
        catch { connectionError = "Report failed: \(error.localizedDescription)" }
        if WCSession.default.isReachable { WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil) }
        reportMessage = "Watch inventory sent to iPhone. \(bookReports.values.filter(\.complete).count) books installed."
    }

    private func report(_ value: WatchManifestAcknowledgement, libraryID: WatchPairedLibraryID? = nil) {
        guard let data = try? WatchProtocolEnvelope.encode(kind: .watchManifest, payload: value,
            libraryID: libraryID ?? snapshot?.pairedLibraryID ?? .unknown, revision: value.revision),
              WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(WatchProtocolEnvelope.dictionary(for: data))
        reportMessage = "Report queued for iPhone. \(value.installedChapterIDs?.count ?? 0) chapters installed."
    }

    private func seedSmoke() {
        let id = WatchBookID("alice")
        snapshot = WatchLibrarySnapshot(pairedLibraryID: "smoke", revision: 1, books: [
            WatchBookDTO(id: id, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll",
                chapters: (1...3).map { WatchChapterDTO(id: WatchChapterID("alice-\($0)"),
                    index: $0 - 1, title: "Chapter \($0)", duration: 640) })])
        bookReports[id] = WatchManifestAcknowledgement(bookID: id, revision: 1, complete: true, installedBytes: 3)
    }
}

extension WatchSessionAdapter: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = activationState == .activated && session.isReachable
        let message = error?.localizedDescription
        Task { @MainActor in self.isReachable = reachable; self.connectionError = message; self.refresh() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.activationState == .activated && session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let box = WatchUncheckedBox(context)
        Task { @MainActor in self.apply(box.value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo info: [String: Any]) {
        let box = WatchUncheckedBox(info)
        Task { @MainActor in self.apply(box.value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = WatchUncheckedBox(message)
        Task { @MainActor in self.apply(box.value) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let box = WatchUncheckedBox(message)
        let reply = WatchUncheckedBox(replyHandler)
        // Acknowledge native delivery before any asynchronous disk reconciliation.
        reply.value(["received": true])
        Task { @MainActor in self.apply(box.value) }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata, let bookID = metadata["bookID"] as? String,
              let name = metadata["chapterFilename"] as? String,
              let bytes = metadata["expectedBytes"] as? Int64,
              let hash = metadata["expectedSHA256"] as? String,
              let revision = metadata["revision"] as? Int64,
              let kind = metadata["assetKind"] as? String,
              kind == "audio-aac96" || kind == "artwork" else { return }
        Self.fileIO.lock()
        defer { Self.fileIO.unlock() }
        var revisions = UserDefaults.standard.dictionary(forKey: "watch.bookRevisions") ?? [:]
        let latest = revisions[bookID] as? Int64 ?? 0
        guard revision >= latest else { return }
        var removed = Set(UserDefaults.standard.stringArray(forKey: "watch.removedBookIDs") ?? [])
        if removed.contains(bookID) {
            guard revision > latest else { return }
            removed.remove(bookID)
            UserDefaults.standard.set(Array(removed), forKey: "watch.removedBookIDs")
        }
        revisions[bookID] = revision
        UserDefaults.standard.set(revisions, forKey: "watch.bookRevisions")
        let validator: ((URL) throws -> Void)?
        if kind == "audio-aac96" { validator = { url in try Self.validateAAC(url) } }
        else { validator = nil }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DownloadedBooks", isDirectory: true)
            _ = try WatchPhonePushFiles.install(source: file.fileURL, root: root, bookID: bookID,
                filename: name, expectedBytes: bytes, expectedSHA256: hash,
                validateAudio: validator)
            Task { @MainActor in
                if kind == "artwork" { self.artworkReceipt = "Artwork installed." }
                else {
                    self.lastReceivedBookID = WatchBookID(bookID)
                    self.audioReceipt = "Audio received and validated; checking installed catalog."
                    UserDefaults.standard.set(self.audioReceipt, forKey: "watch.audioReceipt")
                }
                self.reconcileFiles()
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.audioReceipt = "Installation failed: \(message)"; self.connectionError = message
                var value = self.bookReports[WatchBookID(bookID)] ?? WatchManifestAcknowledgement(
                    bookID: WatchBookID(bookID), revision: revision, complete: false, installedBytes: 0)
                value.complete = false; value.failureMessage = message
                self.report(value)
            }
        }
    }
}

private struct WatchUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
