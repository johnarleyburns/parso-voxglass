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
    private var catalogGeneration: UInt64 = 0
    private var committedGeneration: UInt64 = 0
    nonisolated private static let catalogIngestor = WatchCatalogIngestor()
    // Guards only small UserDefaults bookkeeping shared by native file callbacks and MainActor
    // catalog callbacks. It is never held across file I/O; `files` owns all disk mutation.
    nonisolated private static let metadataLock = NSLock()
    nonisolated private static let files = WatchDownloadedFiles()
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
    private static let installEpochKey = "watch.installEpoch"
    private static var audioRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadedBooks", isDirectory: true)
    }
    /// A random ID minted once per fresh watch-app install, persisted in this app's own
    /// `UserDefaults` — which a delete + reinstall wipes, same as `"watch.reportRevision"`. Lets the
    /// phone's `WatchCatalogAcceptanceResolver` tell "this report's revision is lower because the
    /// watch was reinstalled" apart from a genuinely stale/out-of-order delivery.
    private static var installEpoch: String {
        if let existing = UserDefaults.standard.string(forKey: installEpochKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: installEpochKey)
        return fresh
    }

    override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.resetKey) {
            // Deletion runs off MainActor; the reset flag survives until cleanup succeeds.
            startPendingReset()
        } else { loadSnapshot() }
        if smoke { seedSmoke(); return }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        reconcileFiles(forceReport: true)
    }

    private func loadSnapshot() {
        if let data = UserDefaults.standard.data(forKey: Self.snapshotKey) {
            snapshot = try? JSONDecoder().decode(WatchLibrarySnapshot.self, from: data)
        }
    }

    /// A confirmed reset applies before opening the listening state. Narration outboxes are
    /// deliberately excluded: unsubmitted review events must never be erased.
    private func startPendingReset() {
        let root = Self.audioRoot
        Task { [weak self] in
            do {
                _ = try await Self.files.resetDownloadedState(at: root)
                guard let self else { return }
                Self.metadataLock.withLock {
                    for key in [Self.snapshotKey, "watch.downloaded", "watch.listened", "watch.audioReceipt", "watch.removedBookIDs", "watch.bookRevisions", Self.resetKey] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
                WatchContinueListeningStore.save(nil)
                await Self.catalogIngestor.resetState()
                snapshot = nil
                bookReports = [:]
                phoneTransferProgress = [:]
                audioReceipt = "No audio received yet."
            } catch {
                guard let self else { return }
                connectionError = "Reset failed: \(error.localizedDescription). Relaunch to retry."
                if snapshot == nil { loadSnapshot() }
                reconcileFiles(forceReport: true)
            }
        }
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
        // `replyHandler`/`errorHandler` closures written inline inside this @MainActor class
        // silently inherit MainActor isolation — but WCSession (imported `@preconcurrency`) invokes
        // them on its own background delegate queue, not the main actor. That mismatch isn't a
        // compile error here; it's a Swift 6 runtime isolation trap the instant Apple calls back,
        // which is exactly what made tapping "Sync Now" crash. `@Sendable` keeps these closures from
        // inheriting isolation; any state they touch still hops back via `Task { @MainActor in }`.
        WCSession.default.sendMessage(WatchProtocolEnvelope.dictionary(for: data), replyHandler: { @Sendable _ in },
            errorHandler: { @Sendable [weak self] error in
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

    /// Receipt only extracts immutable `Data` and a generation token; parsing, validation, and
    /// snapshot persistence happen in `catalogIngestor`, off MainActor.
    private func apply(_ dictionary: [String: Any]) {
        guard let data = WatchProtocolEnvelope.payloadData(in: dictionary) else { return }
        catalogGeneration += 1
        let generation = catalogGeneration
        let current = snapshot
        Task { [weak self] in
            let route = await Self.catalogIngestor.route(data, generation: generation, current: current)
            guard let self else { return }
            switch route {
            case .unreadable: break
            case .other(let envelope): handle(envelope)
            case .catalog(let result): commit(result)
            }
        }
    }

    /// The minimal atomic MainActor commit of an accepted catalog.
    private func commit(_ result: WatchCatalogIngestionResult) {
        guard case .accepted(let catalog) = result, catalog.generation > committedGeneration else { return }
        committedGeneration = catalog.generation
        Self.metadataLock.lock()
        defer { Self.metadataLock.unlock() }
        let value = catalog.snapshot
        snapshot = value
        lastCatalogDate = catalog.sentAt
        isSyncing = false
        syncMessage = "Sync updated."
        connectionError = nil
        var removed = Set(UserDefaults.standard.stringArray(forKey: "watch.removedBookIDs") ?? [])
        var revisions = UserDefaults.standard.dictionary(forKey: "watch.bookRevisions") ?? [:]
        for book in catalog.books {
            let latest = revisions[book.bookID] as? Int64 ?? 0
            if book.metadataRevision > latest, !book.isRemoving { removed.remove(book.bookID) }
            revisions[book.bookID] = max(latest, book.metadataRevision)
        }
        UserDefaults.standard.set(revisions, forKey: "watch.bookRevisions")
        UserDefaults.standard.set(Array(removed), forKey: "watch.removedBookIDs")
        if catalog.needsReconciliation { reconcileFiles(forceReport: true) }
        else if !isReconciling { publishCurrentReports() }
    }

    private func handle(_ envelope: WatchProtocolEnvelope) {
        // Only small metadata is guarded here; file I/O never runs under this lock.
        Self.metadataLock.lock()
        defer { Self.metadataLock.unlock() }
        switch envelope.kind {
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
            let root = Self.audioRoot
            let bookID = manifest.bookID
            let revision = manifest.revision
            let libraryID = envelope.pairedLibraryID
            Task { [weak self] in
                do {
                    try await Self.files.removeBook(bookID: bookID, at: root)
                    guard let self else { return }
                    Self.metadataLock.withLock {
                        bookReports.removeValue(forKey: bookID)
                        phoneTransferProgress.removeValue(forKey: bookID)
                        snapshot?.books.removeAll { $0.id == bookID }
                    }
                    if let reduced = snapshot { Task { await Self.catalogIngestor.persist(reduced) } }
                    var removal = WatchManifestAcknowledgement(bookID: bookID, revision: revision,
                        complete: false, installedBytes: 0)
                    removal.isRemoval = true
                    report(removal, libraryID: libraryID)
                    reconcileFiles()
                } catch {
                    // No removal acknowledgement; catalog/report state stays so the phone can retry.
                    self?.connectionError = "Removal failed: \(error.localizedDescription)"
                }
            }
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
                payload: WatchDeviceCatalog(
                    reports: bookReports.values.sorted { $0.bookID.rawValue < $1.bookID.rawValue },
                    installEpoch: Self.installEpoch
                ),
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

    /// Playback positions are a separate, durable stream from the coalesced
    /// watch-inventory context. In particular, a pause while the phone is out
    /// of reach must be delivered when it reconnects.
    func publishPlaybackCheckpoint(_ checkpoint: WatchPlaybackCheckpoint) {
        let revision = Int64(UserDefaults.standard.integer(forKey: "watch.playbackRevision")) + 1
        guard !smoke, WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? WatchProtocolEnvelope.encode(
                kind: .playbackSnapshot,
                payload: checkpoint,
                libraryID: snapshot?.pairedLibraryID ?? .unknown,
                revision: revision
              ) else { return }
        UserDefaults.standard.set(revision, forKey: "watch.playbackRevision")
        let message = WatchProtocolEnvelope.dictionary(for: data)
        WCSession.default.transferUserInfo(message)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
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
        Self.metadataLock.lock()
        var revisions = UserDefaults.standard.dictionary(forKey: "watch.bookRevisions") ?? [:]
        let latest = revisions[bookID] as? Int64 ?? 0
        guard revision >= latest else { Self.metadataLock.unlock(); return }
        var removed = Set(UserDefaults.standard.stringArray(forKey: "watch.removedBookIDs") ?? [])
        if removed.contains(bookID) {
            guard revision > latest else { Self.metadataLock.unlock(); return }
            removed.remove(bookID)
            UserDefaults.standard.set(Array(removed), forKey: "watch.removedBookIDs")
        }
        revisions[bookID] = revision
        UserDefaults.standard.set(revisions, forKey: "watch.bookRevisions")
        Self.metadataLock.unlock()
        let validator: (@Sendable (URL) throws -> Void)?
        if kind == "audio-aac96" { validator = { url in try Self.validateAAC(url) } }
        else { validator = nil }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DownloadedBooks", isDirectory: true)
            _ = try Self.files.install(source: file.fileURL, root: root, bookID: bookID,
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
