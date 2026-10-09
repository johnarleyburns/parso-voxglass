import Foundation
import UIKit
import AVFoundation
import WatchConnectivity
import ParsoAudioStreaming
import VoxglassCore
import VoxglassWatchProtocol
import VoxglassWatchCore

@MainActor
final class PhoneAudioRelay: NSObject, ObservableObject {
    static let shared = PhoneAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isActivated: Bool = false
    @Published private(set) var watchStorageSnapshot: WatchStorageSnapshot?
    @Published private(set) var isTransferringToWatch = false
    @Published private(set) var lastWatchSyncDate: Date?
    @Published private(set) var watchSyncStatus: String?
    @Published var connectionToast: String?
    @Published var watchTransferError: String?
    @Published private(set) var watchSelectedBookIDs = Set<UUID>()
    @Published private(set) var watchCatalogBooks: [WatchBookDTO] = []
    @Published private(set) var watchDesiredStates: [WatchBookID: WatchDownloadState] = [:]
    @Published private(set) var lastCatalogSentDate: Date?
    @Published private(set) var lastWatchReportDate: Date?

    private let session: WCSession
    private weak var libraryStore: LibraryStore?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private weak var offlineManager: OfflineDownloadManager?
    private var watchProjectionStore: PhoneWatchProjectionStore?
    private var lastCatalogContent: WatchLibrarySnapshot?
    private var catalogPublishGeneration = 0
    private var queuedRemovalRevisions: [WatchBookID: Int64] = [:]
    private var watchLibraryID: WatchPairedLibraryID = .init(UserDefaults.standard.string(forKey: "voxglass.watch.libraryID") ?? UUID().uuidString)

    /// The production relay transport. `WCSession` permits a single delegate, which
    /// this relay owns; incoming production messages (review events, refresh
    /// requests) are forwarded here so the watch's offline actions reach the phone.
    weak var productionTransport: WatchConnectivityTransport?

    func registerProductionTransport(_ transport: WatchConnectivityTransport) {
        productionTransport = transport
        transport.updateReachability(reachable: isReachable, activated: session.activationState == .activated)
    }

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
        refreshConnectionState()
    }

    var connectionStatusText: String {
        if !WCSession.isSupported() { return String(localized: "Apple Watch is not supported on this iPhone.") }
        if !isPaired { return String(localized: "No Apple Watch is paired.") }
        if !isWatchAppInstalled { return String(localized: "Voxglass is not installed on the paired Apple Watch.") }
        if !isActivated { return String(localized: "Connecting to Apple Watch…") }
        return isReachable ? String(localized: "Apple Watch connected") : String(localized: "Apple Watch not currently reachable")
    }

    var watchStoredBytes: Int64 {
        watchStorageSnapshot?.books.values.reduce(0) { $0 + $1.byteCount } ?? 0
    }

    var watchStoredBookCount: Int {
        watchStorageSnapshot?.books.values.filter { $0.state == .available }.count ?? 0
    }

    func configure(
        libraryStore: LibraryStore,
        playbackCoordinator: PlaybackCoordinator,
        offlineManager: OfflineDownloadManager? = nil
    ) {
        self.libraryStore = libraryStore
        self.playbackCoordinator = playbackCoordinator
        self.offlineManager = offlineManager
        UserDefaults.standard.set(watchLibraryID.rawValue, forKey: "voxglass.watch.libraryID")
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.watchProjectionStore = PhoneWatchProjectionStore(
            url: support.appendingPathComponent("Voxglass/WatchProjection.json"), libraryID: watchLibraryID
        )
        refreshConnectionState()
        Task {
            if let watchProjectionStore {
                // Existing explicit selections stay manageable, but originals must be
                // re-sent by the user to adopt the new AAC96 profile; never auto-download.
                let old = await watchProjectionStore.current()
                for (id, root) in old.desiredRoots where old.selectedBooks[id] == nil {
                    guard let source = libraryStore.books.first(where: { $0.book.id.uuidString == id.rawValue }) else { continue }
                    let chapters = source.chapters.map { chapter in
                        WatchChapterDTO(id: WatchChapterID(chapter.id.uuidString), index: chapter.index,
                            title: chapter.title, duration: chapter.duration ?? 0, startTime: 0,
                            expectedBytes: nil, expectedSHA256: nil, durableFilename: chapter.id.uuidString + ".m4a")
                    }
                    try? await watchProjectionStore.select(WatchBookDTO(id: id, title: source.book.title,
                        author: source.book.authors.first, narrator: source.book.narrators.first,
                        metadataRevision: root.revision, chapters: chapters))
                    try? await watchProjectionStore.setDesired(.failed("Send again from iPhone to prepare the new watch AAC96 format."), for: id)
                }
                let state = await watchProjectionStore.current()
                watchSelectedBookIDs = Set(state.selectedBooks.keys.compactMap { UUID(uuidString: $0.rawValue) })
                for value in state.acknowledgements.values { applyWatchAcknowledgement(value) }
            }
            await publishLibrarySnapshot()
            await publishTypedWatchProjection()
        }
    }

    func publishTypedWatchProjection(force: Bool = false) async {
        guard let libraryStore, let watchProjectionStore else { return }
        guard session.activationState == .activated else { return }
        catalogPublishGeneration += 1
        let generation = catalogPublishGeneration
        do {
            guard let message = try await makeTypedWatchMessage(
                libraryStore: libraryStore,
                projectionStore: watchProjectionStore, force: force
            ) else { return }
            guard generation == catalogPublishGeneration else { return }
            try session.updateApplicationContext(message)
            if let data = WatchProtocolEnvelope.payloadData(in: message),
               let envelope = try? WatchProtocolEnvelope.decode(data),
               var sent = try? envelope.decodePayload(WatchLibrarySnapshot.self) {
                sent.revision = 0
                lastCatalogContent = sent
            }
            if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
            lastCatalogSentDate = SystemClock().now
            UserDefaults.standard.set(watchLibraryID.rawValue, forKey: "voxglass.watch.libraryID")
            lastWatchSyncDate = Date()
            watchSyncStatus = session.isReachable
                ? String(localized: "Watch catalog sent.")
                : String(localized: "Watch catalog saved for delivery when Apple Watch connects.")
        } catch {
            guard generation == catalogPublishGeneration else { return }
            lastCatalogContent = nil
            watchSyncStatus = String(localized: "Watch sync failed: \(error.localizedDescription)")
        }
    }

    func syncWatchNow() async {
        refreshConnectionState()
        guard isPaired else { watchSyncStatus = String(localized: "No Apple Watch is paired."); return }
        guard isWatchAppInstalled else {
            watchSyncStatus = String(localized: "Install Voxglass on the paired Apple Watch first.")
            return
        }
        guard libraryStore != nil, watchProjectionStore != nil else {
            watchSyncStatus = String(localized: "The iPhone app is still starting.")
            return
        }
        await publishTypedWatchProjection(force: true)
        if isReachable { connectionToast = String(localized: "Apple Watch connected") }
    }

    private func makeTypedWatchMessage(
        libraryStore: LibraryStore,
        projectionStore: PhoneWatchProjectionStore,
        correlationID: UUID? = nil, force: Bool = false
    ) async throws -> [String: Any]? {
        try await projectionStore.expireTransfers(at: SystemClock().now)
        let state = await projectionStore.current()
        var snapshot = WatchLibrarySnapshot(pairedLibraryID: watchLibraryID, revision: 0,
            books: state.selectedBooks.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        snapshot.downloadStates = state.desired
        watchCatalogBooks = snapshot.books
        watchDesiredStates = state.desired
        if let playback = playbackCoordinator, let session = playback.currentSession {
            snapshot = PhoneWatchProjection.applyingResumePosition(
                bookID: WatchBookID(session.book.id.uuidString),
                chapterID: WatchChapterID(session.chapter.id.uuidString),
                position: playback.playhead,
                to: snapshot
            )
        }
        guard force || snapshot != lastCatalogContent else { return nil }
        let revision = try await projectionStore.nextRevision()
        snapshot.revision = revision
        let data = try WatchProtocolEnvelope.encode(
            kind: .librarySnapshot,
            payload: snapshot,
            libraryID: watchLibraryID,
            revision: revision,
            correlationID: correlationID
        )
        for (id, desired) in state.desired where desired == .removing {
            guard let root = state.desiredRoots[id], queuedRemovalRevisions[id] != root.revision else { continue }
            let removal = try WatchProtocolEnvelope.encode(kind: .removeBookDownload, payload: root,
                libraryID: watchLibraryID, revision: root.revision)
            session.transferUserInfo(WatchProtocolEnvelope.dictionary(for: removal))
            if session.isReachable { session.sendMessage(WatchProtocolEnvelope.dictionary(for: removal), replyHandler: nil, errorHandler: nil) }
            queuedRemovalRevisions[id] = root.revision
        }
        return WatchProtocolEnvelope.dictionary(for: data)
    }

    func publishLibrarySnapshot() async {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        await publishTypedWatchProjection()
    }

    /// `bookID`/`chapterFilename`/`totalChapterCount` make a phone→watch push
    /// transfer (from `transferBookToWatch`) self-describing, so the watch's
    /// `WCSessionDelegate.session(_:didReceive:)` can file the received bytes
    /// under the same `DownloadedBooks/<bookID>/<filename>` layout its own
    /// HTTP download path already uses, and know when a book is complete —
    /// without depending on a separately-delivered manifest arriving first
    /// (file transfers and messages aren't ordered relative to each other).
    /// Left `nil` for the single just-in-time chapter reply in
    /// `findAndSendChapter`, which has no book-level context to offer.
    @discardableResult
    func transferChapterFile(
        at url: URL,
        chapterKey: String,
        bookID: UUID? = nil,
        chapterFilename: String? = nil,
        totalChapterCount: Int? = nil,
        expectedBytes: Int64? = nil, expectedSHA256: String? = nil, revision: Int64 = 0
    ) -> WCSessionFileTransfer {
        var metadata: [String: Any] = ["chapterKey": chapterKey]
        if let bookID { metadata["bookID"] = bookID.uuidString }
        if let chapterFilename { metadata["chapterFilename"] = chapterFilename }
        if let totalChapterCount { metadata["totalChapterCount"] = totalChapterCount }
        if let expectedBytes { metadata["expectedBytes"] = expectedBytes }
        if let expectedSHA256 { metadata["expectedSHA256"] = expectedSHA256 }
        metadata["assetKind"] = "audio-aac96"
        metadata["revision"] = revision
        return session.transferFile(url, metadata: metadata)
    }

    func watchStorageInfo(for bookID: UUID) -> WatchBookStorageInfo? {
        watchStorageSnapshot?.storageInfo(for: bookID)
    }

    private func reply(for message: [String: Any]) async -> [String: Any] {
        guard let action = WatchPhoneMessageCodec.action(from: message) else {
            return WatchPhoneMessageCodec.errorReply(WatchPhoneMessageError.missingAction.localizedDescription)
        }

        do {
            switch action {
            case WatchPhoneAction.requestLibrary, WatchPhoneAction.searchLibriVox,
                 WatchPhoneAction.playBook, WatchPhoneAction.playRemote:
                return WatchPhoneMessageCodec.errorReply("Choose and send books from your iPhone. The watch only plays installed audio.")

            case WatchPhoneAction.requestPlaybackState:
                return try WatchPhoneMessageCodec.reply(playbackState(accepted: true))

            case WatchPhoneAction.playbackCommand:
                let request = try WatchPhoneMessageCodec.payload(WatchPhonePlaybackCommandRequest.self, from: message)
                let state = await handlePlaybackCommand(request)
                return try WatchPhoneMessageCodec.reply(state)

            case WatchPhoneAction.reportWatchStorage:
                let snapshot = try WatchPhoneMessageCodec.payload(WatchStorageSnapshot.self, from: message)
                applyWatchStorageSnapshot(snapshot)
                return try WatchPhoneMessageCodec.reply(WatchPhoneEmptyPayload())

            default:
                return WatchPhoneMessageCodec.errorReply("Unsupported watch action: \(action)")
            }
        } catch {
            return WatchPhoneMessageCodec.errorReply(error.localizedDescription)
        }
    }

    private func handlePlaybackCommand(_ request: WatchPhonePlaybackCommandRequest) async -> WatchPhonePlaybackState {
        guard let playbackCoordinator else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: String(localized: "The iPhone app is still starting."))
        }

        switch request.command {
        case .togglePlayPause:
            playbackCoordinator.togglePlayPause()
        case .pause:
            playbackCoordinator.pause()
        case .skipBackward:
            await playbackCoordinator.skip(by: -(request.seconds ?? 15))
        case .skipForward:
            await playbackCoordinator.skip(by: request.seconds ?? 30)
        case .previousChapter:
            await playbackCoordinator.skipToPreviousChapter()
        case .nextChapter:
            await playbackCoordinator.skipToNextChapter()
        }

        try? await Task.sleep(for: .milliseconds(150))
        return playbackState(accepted: playbackCoordinator.currentSession != nil)
    }

    private func playbackState(accepted: Bool) -> WatchPhonePlaybackState {
        guard let playbackCoordinator else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: String(localized: "The iPhone app is still starting."))
        }

        var session = playbackCoordinator.currentSession
        if var liveSession = session {
            liveSession.position = playbackCoordinator.playhead
            liveSession.duration = playbackCoordinator.playheadDuration ?? liveSession.duration
            liveSession.isPlaying = playbackCoordinator.playbackPhase == .playing
            session = liveSession
        }

        return WatchPhonePlaybackState(
            accepted: accepted,
            session: session,
            errorMessage: playbackCoordinator.playbackError
        )
    }

    /// Routes a production-relay message (review event, refresh request) to the
    /// registered transport. Consumer messages are untouched.
    @MainActor
    private func forwardProduction(_ message: [String: Any]) {
        guard let transport = productionTransport else { return }
        transport.handleIncoming(message)
    }

    private func handleReceivedMessageWithoutReply(_ message: [String: Any]) async {
        guard let action = message["action"] as? String else { return }
        switch action {
        case "requestChapterFile":
            // Retired: audio is explicitly selected and prepared on the phone only.
            return
        case WatchPhoneAction.reportWatchStorage:
            if let snapshot = try? WatchPhoneMessageCodec.payload(WatchStorageSnapshot.self, from: message) {
                applyWatchStorageSnapshot(snapshot)
            }
        default:
            break
        }
    }

    private func applyWatchStorageSnapshot(_ snapshot: WatchStorageSnapshot) {
        watchStorageSnapshot = snapshot
    }

    private func applyWatchAcknowledgement(_ acknowledgement: WatchManifestAcknowledgement) {
        guard let id = UUID(uuidString: acknowledgement.bookID.rawValue) else { return }
        let state: WatchTransferState
        if acknowledgement.complete { state = .available }
        else if acknowledgement.failureMessage != nil { state = .failed }
        else if case .failed? = watchDesiredStates[acknowledgement.bookID] { state = .failed }
        else if case .transferring(let progress)? = watchStorageSnapshot?.books[id]?.state {
            state = .transferring(progress: progress)
        } else { state = .queued }
        let total = watchCatalogBooks.first { $0.id == acknowledgement.bookID }?.chapters.count
            ?? watchStorageSnapshot?.books[id]?.totalChapterCount ?? 0
        let installed = acknowledgement.installedChapterIDs?.count ?? (acknowledgement.complete ? total : 0)
        let info = WatchBookStorageInfo(
            state: state,
            byteCount: acknowledgement.installedBytes,
            chapterCount: installed,
            completeChapterCount: installed,
            totalChapterCount: total
        )
        var books = watchStorageSnapshot?.books ?? [:]
        books[id] = info
        applyWatchStorageSnapshot(WatchStorageSnapshot(books: books))
    }

    private func refreshConnectionState() {
        guard WCSession.isSupported() else { return }
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isActivated = session.activationState == .activated
        isReachable = session.isReachable
    }

    // MARK: - Phone-push transfer (consumer "Download to Apple Watch", RC4)

    /// Outcome of asking the phone to send a book to the watch — lets the UI
    /// decide whether to present the cellular prompt before anything starts.
    enum WatchTransferStart: Equatable {
        case started
        case needsCellularConfirmation
        case failed(String)
    }

    /// Sends a book's chapters to the watch for offline listening. If the phone
    /// doesn't already hold the book's blobs it downloads them first (gated by
    /// the offline cellular policy), then transfers every complete chapter with
    /// the background-capable `WCSession.transferFile`. The watch ingests each
    /// file into `voxglass-watch-audio` and publishes its storage snapshot back
    /// for progress display.
    /// A chapter whose audio is a bookmark-referenced local file (a folder
    /// import, or a personal-listening export) is already a complete blob
    /// sitting outside `AudioCache` entirely — it was never downloaded and
    /// never will be. Transferring it to the watch just needs this URL
    /// directly; routing it through the remote-download cache lookup below
    /// would always resolve to nothing.
    private func localOnDiskURL(for chapter: Chapter) -> URL? {
        guard let url = chapter.resolvedPlayableURL(), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func transferBookToWatch(
        _ book: BookWithChapters,
        allowCellularOverride: Bool = false
    ) async -> WatchTransferStart {
        refreshConnectionState()
        guard !isTransferringToWatch else { return .failed("Another book is being prepared for Apple Watch.") }
        guard session.activationState == .activated else { return .failed("The watch connection is still starting. Try again when connected.") }
        guard isWatchAppInstalled else {
            return .failed("The Voxglass app isn't installed on your Apple Watch.")
        }
        guard let offlineManager else {
            return .failed("The iPhone app is still starting.")
        }
        isTransferringToWatch = true
        defer { isTransferringToWatch = false }

        // A book whose chapters are all already-local files (never queued
        // through the download pipeline, and with no remote source to
        // download from) skips the "make it available offline first" step
        // entirely — there's nothing to download.
        let needsPhoneDownload = book.chapters.contains { localOnDiskURL(for: $0) == nil }

        if needsPhoneDownload, offlineManager.state(for: book.book.id) != .cached {
            let decision = await offlineManager.makeAvailableOffline(
                book: book,
                isCellular: NetworkMonitor.shared.isCellular,
                allowCellularOverride: allowCellularOverride
            )
            guard decision == .start else { return .needsCellularConfirmation }
        }

        guard let watchProjectionStore else { return .failed("The watch library is not ready.") }
        let revision = (try? await watchProjectionStore.nextRevision()) ?? 0
        var selected = WatchBookDTO(id: WatchBookID(book.book.id.uuidString), title: book.book.title,
            author: book.book.authors.first, narrator: book.book.narrators.first,
            duration: book.totalDuration ?? 0, metadataRevision: revision,
            chapters: book.chapters.map {
                WatchChapterDTO(id: WatchChapterID($0.id.uuidString), index: $0.index,
                    title: $0.title, duration: $0.duration ?? 0, startTime: 0,
                    expectedBytes: nil, expectedSHA256: nil, durableFilename: $0.id.uuidString + ".m4a")
            })
        do {
            try await watchProjectionStore.select(selected)
            try await watchProjectionStore.setDesiredRoot(WatchManifest(bookID: selected.id, revision: revision,
                requiredChapterIDs: selected.chapters.map(\.id)))
            try await watchProjectionStore.setDesired(.preparing, for: selected.id)
            watchSelectedBookIDs.insert(book.book.id)
            await publishTypedWatchProjection()
        } catch { return .failed("Couldn't save this watch selection: \(error.localizedDescription)") }
        // This is an explicit user submission. Retire an older submission for this
        // same book so it cannot waste the transfer queue or mask new progress.
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["bookID"] as? String == book.book.id.uuidString {
            transfer.cancel()
        }

        func fail(_ message: String) async -> WatchTransferStart {
            var storage = watchStorageSnapshot?.books ?? [:]
            storage[book.book.id] = WatchBookStorageInfo(
                state: .failed,
                byteCount: 0,
                chapterCount: 0,
                completeChapterCount: 0,
                totalChapterCount: book.chapters.count
            )
            applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))
            try? await watchProjectionStore.setDesired(.failed(message), for: selected.id)
            watchTransferError = message
            await publishTypedWatchProjection()
            return .failed(message)
        }

        var storage = watchStorageSnapshot?.books ?? [:]
        storage[book.book.id] = WatchBookStorageInfo(
            state: .queued,
            byteCount: 0,
            chapterCount: 0,
            completeChapterCount: 0,
            totalChapterCount: book.chapters.count
        )
        applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))

        if needsPhoneDownload {
            // Wait for the phone-side download to complete before
            // transferring. A flat time cap here (the original version of
            // this) doesn't work for a real audiobook — a full novel can
            // take longer than any reasonable fixed wait to download, and
            // when the old 180s cap elapsed mid-download, this fell through
            // and proceeded to transfer anyway with whichever chapters
            // happened to be cached so far. Since the watch is separately
            // told the book's FULL chapter count and can only ever
            // acknowledge once every one of them has arrived, that silently
            // guaranteed a transfer that could never complete — reproduced
            // live with "Murder on the Orient Express". Watch the download's
            // own reported progress instead, and only give up once it
            // genuinely stalls.
            var lastProgress = -1.0
            var lastProgressAt = Date()
            let stallTimeout: TimeInterval = 120
            let absoluteTimeout: TimeInterval = 90 * 60
            let startedAt = Date()
            var state = offlineManager.state(for: book.book.id)
            while case .downloading(let progress) = state {
                if progress > lastProgress {
                    lastProgress = progress
                    lastProgressAt = Date()
                }
                let stalled = Date().timeIntervalSince(lastProgressAt) > stallTimeout
                let tooLong = Date().timeIntervalSince(startedAt) > absoluteTimeout
                if stalled || tooLong {
                    return await fail("The book stopped downloading to the iPhone before it finished.")
                }
                try? await Task.sleep(for: .milliseconds(500))
                state = offlineManager.state(for: book.book.id)
            }
            if state == .failed {
                return await fail("The book couldn't be downloaded on the iPhone.")
            }
        }

        // Resolve every chapter's local file BEFORE sending anything. The
        // watch is told the book's full chapter count up front and can only
        // ever acknowledge once every one of them has arrived — silently
        // sending fewer (the original version of this skipped whichever
        // chapters weren't resolvable yet) guarantees a transfer that can
        // never complete, no matter how patient anything downstream is.
        var resolvedChapterFiles: [(chapter: Chapter, key: String, url: URL)] = []
        for chapter in book.chapters {
            guard let key = ChapterAudioIdentity.cacheKey(for: chapter) else {
                return await fail("A chapter's audio file couldn't be identified.")
            }
            if let localURL = localOnDiskURL(for: chapter) {
                resolvedChapterFiles.append((chapter, key, localURL))
                continue
            }
            guard let fileURL = await WatchChapterTransfer.resolvedFileURL(
                cacheStore: AudioCache.shared,
                chapterKey: key
            ) else {
                return await fail("Not every chapter has finished downloading to the iPhone yet.")
            }
            resolvedChapterFiles.append((chapter, key, fileURL))
        }
        guard !resolvedChapterFiles.isEmpty else {
            return await fail("No chapters were ready to transfer.")
        }

        var preparedFiles: [(Chapter, String, URL, Int64, String)] = []
        var sourceHashes: [URL: String] = [:]
        var artwork: (url: URL, bytes: Int64, hash: String)?
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Voxglass/WatchAAC96", isDirectory: true)
            selected.chapters = []
            for (chapter, key, source) in resolvedChapterFiles {
                watchSyncStatus = "Preparing watch AAC: \(chapter.title)"
                let hash: String
                if let cached = sourceHashes[source] { hash = cached }
                else {
                    hash = try await Task.detached {
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                        return try WatchChecksum.sha256(of: source)
                    }.value
                    sourceHashes[source] = hash
                }
                let remote = chapter.remoteURL
                let mime = remote.flatMap { RemoteAudioURL.contentTypeMIME(for: $0) }
                    ?? (remote?.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : nil)
                let url = try await WatchChapterTransfer.prepareAAC(source: source, directory: directory,
                    startTime: max(0, chapter.startTime), duration: chapter.duration.flatMap { $0 > 0 ? $0 : nil },
                    sourceHash: hash, mimeType: mime)
                let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let checksum = try await Task.detached { try WatchChecksum.sha256(of: url) }.value
                let filename = "\(chapter.id.uuidString).m4a"
                let preparedDuration = try await AVURLAsset(url: url).load(.duration).seconds
                selected.chapters.append(WatchChapterDTO(id: WatchChapterID(chapter.id.uuidString),
                    index: chapter.index, title: chapter.title, duration: preparedDuration, startTime: 0,
                    expectedBytes: size, expectedSHA256: checksum, durableFilename: filename))
                preparedFiles.append((chapter, key, url, size, checksum))
            }
            selected.duration = selected.chapters.reduce(0) { $0 + $1.duration }
            artwork = await prepareWatchArtwork(book: book, directory: directory)
            if let artwork { selected.artworkKey = "\(book.book.id.uuidString)/\(artwork.hash).jpg" }
            try await watchProjectionStore.select(selected)
            watchSelectedBookIDs.insert(book.book.id)
            try await watchProjectionStore.setDesiredRoot(WatchManifest(bookID: selected.id, revision: revision,
                requiredChapterIDs: selected.chapters.map(\.id)))
            await publishTypedWatchProjection()
        } catch {
            try? await watchProjectionStore.setDesired(.failed("AAC preparation failed: \(error.localizedDescription)"), for: selected.id)
            return await fail("The iPhone could not prepare watch AAC. No audio file was submitted. \(error.localizedDescription)")
        }

        do { try await watchProjectionStore.markSubmitted(selected.id, at: SystemClock().now) }
        catch { return await fail("Could not save the transfer state. No audio file was submitted.") }
        let fileTransfers = preparedFiles.map { chapter, key, url, bytes, hash in
            transferChapterFile(
                at: url,
                chapterKey: key,
                bookID: book.book.id,
                chapterFilename: "\(chapter.id.uuidString).m4a",
                totalChapterCount: book.chapters.count,
                expectedBytes: bytes, expectedSHA256: hash, revision: selected.metadataRevision
            )
        }
        if let artwork {
            session.transferFile(artwork.url, metadata: ["assetKind": "artwork", "bookID": book.book.id.uuidString,
                "chapterFilename": artwork.hash + ".jpg", "expectedBytes": artwork.bytes,
                "expectedSHA256": artwork.hash, "revision": selected.metadataRevision])
        }
        // The legacy transfer queue above already carries the complete,
        // self-describing chapter set. Publish the typed manifest without
        // enqueueing a duplicate copy of every audio file.
        await publishTypedWatchProjection()
        watchSyncStatus = "\(book.book.title) queued for Apple Watch."
        watchTransferSupervisor(for: book.book.id, fileTransfers: fileTransfers)
        return .started
    }

    /// Prepare a bounded cover on the phone. The watch never fetches an artwork URL.
    private func prepareWatchArtwork(book: BookWithChapters, directory: URL) async -> (url: URL, bytes: Int64, hash: String)? {
        guard let cover = book.book.coverURL else { return nil }
        let source = LocalArtworkStore.resolve(cover.absoluteString) ?? cover
        do {
            let data: Data
            if source.isFileURL { data = try await Task.detached { try Data(contentsOf: source) }.value }
            else {
                let (received, response) = try await URLSession.shared.data(from: source)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                data = received
            }
            guard data.count <= 20_000_000, let image = UIImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return nil }
            let factor = min(1, 320 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = thumbnail.jpegData(compressionQuality: 0.8) else { return nil }
            let hash = SHA256Hex.hex(jpeg)
            let url = directory.appendingPathComponent(hash + ".jpg")
            if !FileManager.default.fileExists(atPath: url.path) { try jpeg.write(to: url, options: .atomic) }
            return (url, Int64(jpeg.count), hash)
        } catch {
            watchSyncStatus = "Audio preparation continues; artwork could not be prepared."
            return nil
        }
    }

    /// `WCSessionFileTransfer.progress` is a real, live-updating `Progress`
    /// per file — `Progress.addChild(_:withPendingUnitCount:)` composes them
    /// into one aggregate the same way Foundation composes any multi-part
    /// operation, so the book's overall completion fraction is exact, not
    /// estimated from elapsed time or chapter count alone.
    ///
    /// This single task both drives that progress display AND decides when
    /// to give up. A large audiobook over a slow Bluetooth link can
    /// legitimately take many minutes — a flat "fail after N seconds"
    /// watchdog (the first version of this) marked a book that was still
    /// genuinely, if slowly, transferring as failed, live-reproduced with
    /// "Murder on the Orient Express". What actually indicates a stuck
    /// transfer is the complete ABSENCE of progress for a while, not elapsed
    /// time on its own — so this only gives up once the fraction complete
    /// hasn't budged for `stallTimeout`, with a very generous absolute cap
    /// as a last-resort safety net against a runaway task.
    private func watchTransferSupervisor(
        for bookID: UUID,
        fileTransfers: [WCSessionFileTransfer],
        // Audiobooks can be 1+ GB, and WCSession file transfer over
        // Bluetooth is slow — a real, large book can legitimately take a
        // long time without progress. Apple owns delivery; only after 24 hours
        // do we offer an explicit user retry, never submit another file ourselves.
        stallTimeout: TimeInterval = 24 * 60 * 60,
        absoluteTimeout: TimeInterval = 24 * 60 * 60
    ) {
        guard !fileTransfers.isEmpty else { return }
        let aggregate = Progress(totalUnitCount: Int64(fileTransfers.count))
        for transfer in fileTransfers {
            aggregate.addChild(transfer.progress, withPendingUnitCount: 1)
        }
        Task { [weak self] in
            let startedAt = Date()
            var lastFraction = -1.0
            var lastProgressAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                // Once a later event (the watch's ack, or a genuine failure
                // reported some other way) has already moved this book to a
                // terminal state, stop — never clobber that outcome with a
                // stale "still transferring".
                switch self.watchStorageSnapshot?.books[bookID]?.state {
                case .queued, .transferring: break
                default: return
                }

                let fraction = aggregate.fractionCompleted
                if fraction > lastFraction {
                    lastFraction = fraction
                    lastProgressAt = Date()
                }

                // All bytes have been handed off to WCSession — the watch's
                // receive-and-acknowledge path now owns finishing this book
                // off to `.available`. Keep watching for a stall even here:
                // if the watch never acks (a crash mid-install, an outdated
                // build with no receiver), that's exactly the silent-forever
                // case this supervisor exists to catch.
                if fraction < 1 {
                    self.applyWatchTransferProgress(bookID: bookID, fraction: fraction)
                }

                let stalled = Date().timeIntervalSince(lastProgressAt) > stallTimeout
                let tooLong = Date().timeIntervalSince(startedAt) > absoluteTimeout
                guard stalled || tooLong else { continue }

                var storage = self.watchStorageSnapshot?.books ?? [:]
                let previous = storage[bookID]
                storage[bookID] = WatchBookStorageInfo(
                    state: .failed,
                    byteCount: previous?.byteCount ?? 0,
                    chapterCount: previous?.chapterCount ?? 0,
                    completeChapterCount: previous?.completeChapterCount ?? 0,
                    totalChapterCount: previous?.totalChapterCount ?? 0
                )
                self.applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))
                try? await self.watchProjectionStore?.setDesired(.failed("Not installed after 24 hours. Try again from iPhone if needed."), for: WatchBookID(bookID.uuidString))
                await self.publishTypedWatchProjection()
                return
            }
        }
    }

    private func applyWatchTransferProgress(bookID: UUID, fraction: Double) {
        var storage = watchStorageSnapshot?.books ?? [:]
        let previous = storage[bookID]
        storage[bookID] = WatchBookStorageInfo(
            state: .transferring(progress: fraction),
            byteCount: previous?.byteCount ?? 0,
            chapterCount: previous?.chapterCount ?? 0,
            completeChapterCount: previous?.completeChapterCount ?? 0,
            totalChapterCount: previous?.totalChapterCount ?? 0
        )
        applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))
    }

    func removeBookFromWatch(bookID: UUID) async {
        guard let watchProjectionStore else { return }
        let id = WatchBookID(bookID.uuidString)
        let revision = (try? await watchProjectionStore.nextRevision()) ?? 0
        try? await watchProjectionStore.remove(bookID: id, revision: revision)
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["bookID"] as? String == bookID.uuidString {
            transfer.cancel()
        }
        await publishTypedWatchProjection(force: true)
    }
}

extension PhoneAudioRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Extract Sendable scalars before crossing into the MainActor task —
        // `WCSession` is non-Sendable, so capturing it would be a data race.
        let reachable = session.isReachable
        let installed = session.isWatchAppInstalled
        let paired = session.isPaired
        let activated = session.activationState == .activated
        Task { @MainActor in
            let becameConnected = !isReachable && reachable
            isReachable = reachable
            isWatchAppInstalled = installed
            isPaired = paired
            isActivated = activated
            productionTransport?.updateReachability(reachable: reachable, activated: activated)
            if becameConnected {
                connectionToast = String(localized: "Apple Watch connected")
            }
            await publishLibrarySnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let installed = session.isWatchAppInstalled
        let paired = session.isPaired
        let activated = session.activationState == .activated
        Task { @MainActor in
            isReachable = reachable
            isWatchAppInstalled = installed
            isPaired = paired
            isActivated = activated
            productionTransport?.updateReachability(reachable: reachable, activated: activated)
            if installed {
                await publishTypedWatchProjection()
            }
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let installed = session.isWatchAppInstalled
        let paired = session.isPaired
        let activated = session.activationState == .activated
        Task { @MainActor in
            let becameConnected = !isReachable && reachable
            isReachable = reachable
            isWatchAppInstalled = installed
            isPaired = paired
            isActivated = activated
            productionTransport?.updateReachability(reachable: reachable, activated: activated)
            if becameConnected {
                connectionToast = String(localized: "Apple Watch connected")
            }
            if reachable {
                await publishTypedWatchProjection(force: true)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        let box = UncheckedBox(message)
        Task { @MainActor in
            forwardProduction(box.value)
            await handleTypedWatchMessage(box.value)
            await handleReceivedMessageWithoutReply(box.value)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let message = error?.localizedDescription,
              fileTransfer.file.metadata?["assetKind"] as? String == "audio-aac96",
              let bookID = fileTransfer.file.metadata?["bookID"] as? String else { return }
        let revision = (fileTransfer.file.metadata?["revision"] as? NSNumber)?.int64Value ?? 0
        Task { @MainActor in
            guard let store = watchProjectionStore else { return }
            let id = WatchBookID(bookID)
            let state = await store.current()
            guard state.desired[id] != .removing,
                  state.desiredRoots[id]?.revision == revision,
                  !state.acknowledgements.values.contains(where: { $0.bookID == id && $0.complete && $0.revision == revision }) else { return }
            let reason = "Apple could not deliver the audio: \(message). Try again from iPhone if needed."
            try? await store.setDesired(.failed(reason), for: id)
            watchTransferError = reason
            if let uuid = UUID(uuidString: bookID) {
                var books = watchStorageSnapshot?.books ?? [:]
                let previous = books[uuid]
                books[uuid] = WatchBookStorageInfo(state: .failed, byteCount: previous?.byteCount ?? 0,
                    chapterCount: previous?.chapterCount ?? 0, completeChapterCount: previous?.completeChapterCount ?? 0,
                    totalChapterCount: previous?.totalChapterCount ?? 0)
                applyWatchStorageSnapshot(WatchStorageSnapshot(books: books))
            }
            await publishTypedWatchProjection()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        let box = UncheckedBox(userInfo)
        Task { @MainActor in
            forwardProduction(box.value)
            await handleTypedWatchMessage(box.value)
        }
    }

    private func handleTypedWatchMessage(_ message: [String: Any]) async {
        guard let data = WatchProtocolEnvelope.payloadData(in: message),
              let envelope = try? WatchProtocolEnvelope.decode(data) else { return }
        switch envelope.kind {
        case .watchCatalog:
            guard envelope.pairedLibraryID == watchLibraryID,
                  let catalog = try? envelope.decodePayload(WatchDeviceCatalog.self),
                  let store = watchProjectionStore else { return }
            // Reject older whole-device snapshots; receipt time alone is not ordering.
            let reportKey = "voxglass.watch.reportRevision"
            guard envelope.projectionRevision >= Int64(UserDefaults.standard.integer(forKey: reportKey)) else { return }
            UserDefaults.standard.set(envelope.projectionRevision, forKey: reportKey)
            try? await store.reconcile(catalog)
            let state = await store.current()
            watchSelectedBookIDs = Set(state.selectedBooks.keys.compactMap { UUID(uuidString: $0.rawValue) })
            watchDesiredStates = state.desired
            // Rebuild from actual watch inventory, not historical file hand-off progress.
            let progress = (watchStorageSnapshot?.books ?? [:]).filter { id, value in
                if case .transferring = value.state { return state.desired[WatchBookID(id.uuidString)] == .transferring }
                return false
            }
            watchStorageSnapshot = WatchStorageSnapshot(books: progress)
            for report in state.acknowledgements.values { applyWatchAcknowledgement(report) }
            lastWatchReportDate = SystemClock().now
            await publishTypedWatchProjection()
        case .watchManifest:
            guard envelope.pairedLibraryID == watchLibraryID else { return }
            guard let acknowledgement = try? envelope.decodePayload(WatchManifestAcknowledgement.self),
                  let store = watchProjectionStore else { return }
            let before = await store.current()
            if before.desired[acknowledgement.bookID] == .removing, acknowledgement.isRemoval != true { return }
            if let root = before.desiredRoots[acknowledgement.bookID], acknowledgement.revision < root.revision { return }
            try? await store.acknowledge(acknowledgement)
            lastWatchReportDate = SystemClock().now
            let state = await store.current()
            watchSelectedBookIDs = Set(state.selectedBooks.keys.compactMap { UUID(uuidString: $0.rawValue) })
            if !acknowledgement.complete, acknowledgement.installedBytes == 0,
               state.selectedBooks[acknowledgement.bookID] == nil,
               let id = UUID(uuidString: acknowledgement.bookID.rawValue) {
                var books = watchStorageSnapshot?.books ?? [:]
                books.removeValue(forKey: id)
                applyWatchStorageSnapshot(WatchStorageSnapshot(books: books))
            } else { applyWatchAcknowledgement(acknowledgement) }
            await publishTypedWatchProjection()
        case .setBookDownload:
            // The watch is a local player, never an initiator of audio downloads.
            return
        case .reconcileRequest, .hello:
            await publishTypedWatchProjection(force: true)
        default:
            break
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let box = UncheckedBox(applicationContext)
        Task { @MainActor in
            forwardProduction(box.value)
            await handleTypedWatchMessage(box.value)
            if WatchPhoneMessageCodec.action(from: box.value) == WatchPhoneAction.reportWatchStorage,
               let snapshot = try? WatchPhoneMessageCodec.payload(WatchStorageSnapshot.self, from: box.value) {
                applyWatchStorageSnapshot(snapshot)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let messageBox = UncheckedBox(message)
        let replyBox = UncheckedBox(replyHandler)
        Task { @MainActor in
            if let data = WatchProtocolEnvelope.payloadData(in: messageBox.value),
               let envelope = try? WatchProtocolEnvelope.decode(data), envelope.kind == .reconcileRequest {
                // Native receipt is immediate; metadata is independently pushed, not returned
                // as a confirmation payload or gated on a watch acknowledgement.
                replyBox.value(["accepted": true])
                await publishTypedWatchProjection(force: true)
                return
            }
            if let data = WatchProtocolEnvelope.payloadData(in: messageBox.value),
               let envelope = try? WatchProtocolEnvelope.decode(data),
               envelope.kind == .hello,
               let libraryStore, let watchProjectionStore,
               let replyMessage = try? await makeTypedWatchMessage(
                   libraryStore: libraryStore,
                   projectionStore: watchProjectionStore,
                   correlationID: envelope.messageID
               ) {
                replyBox.value(replyMessage)
                try? self.session.updateApplicationContext(replyMessage)
                lastWatchSyncDate = Date()
                watchSyncStatus = String(localized: "My Books sent to Apple Watch.")
                return
            }
            if WatchPhoneMessageCodec.action(from: messageBox.value) == ProductionTransportAction.requestRefresh
                || WatchPhoneMessageCodec.action(from: messageBox.value) == ProductionTransportAction.recordingRemoteCommand {
                // The watch asked the phone to re-push, or sent a recording-remote
                // command; forward to the production relay and acknowledge.
                forwardProduction(messageBox.value)
                replyBox.value(["received": true])
                return
            }
            replyBox.value(await reply(for: messageBox.value))
        }
    }
}

/// Bridges a non-Sendable value across an isolation boundary when the call site
/// guarantees single-threaded handoff (WCSession delivers delegate callbacks
/// synchronously; the value is only consumed inside the MainActor task).
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
