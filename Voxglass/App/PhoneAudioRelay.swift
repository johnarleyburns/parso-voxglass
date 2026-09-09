import Foundation
import WatchConnectivity
import ParsoAudioStreaming
import VoxglassCore
import VoxglassWatchProtocol

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

    private let session: WCSession
    private let client: InternetArchiveCatalogClient
    private weak var libraryStore: LibraryStore?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private weak var offlineManager: OfflineDownloadManager?
    private var watchProjectionStore: PhoneWatchProjectionStore?
    private var watchLibraryID: WatchPairedLibraryID = .init(UserDefaults.standard.string(forKey: "voxglass.watch.libraryID") ?? UUID().uuidString)

    /// The production relay transport. `WCSession` permits a single delegate, which
    /// this relay owns; incoming production messages (review events, refresh
    /// requests) are forwarded here so the watch's offline actions reach the Mac.
    weak var productionTransport: WatchConnectivityTransport?

    func registerProductionTransport(_ transport: WatchConnectivityTransport) {
        productionTransport = transport
        transport.updateReachability(reachable: isReachable, activated: session.activationState == .activated)
    }

    override init() {
        client = InternetArchiveClient()
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
        if !WCSession.isSupported() { return "Apple Watch is not supported on this iPhone." }
        if !isPaired { return "No Apple Watch is paired." }
        if !isWatchAppInstalled { return "Voxglass is not installed on the paired Apple Watch." }
        if !isActivated { return "Connecting to Apple Watch…" }
        return isReachable ? "Apple Watch connected" : "Apple Watch not currently reachable"
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
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.watchProjectionStore = PhoneWatchProjectionStore(
            url: support.appendingPathComponent("Voxglass/WatchProjection.json"), libraryID: watchLibraryID
        )
        refreshConnectionState()
        Task {
            await publishLibrarySnapshot()
            await publishTypedWatchProjection()
        }
    }

    func publishTypedWatchProjection() async {
        guard let libraryStore, let watchProjectionStore else { return }
        do {
            guard let message = try await makeTypedWatchMessage(
                libraryStore: libraryStore,
                projectionStore: watchProjectionStore
            ) else { return }
            try session.updateApplicationContext(message)
            UserDefaults.standard.set(watchLibraryID.rawValue, forKey: "voxglass.watch.libraryID")
            lastWatchSyncDate = Date()
            watchSyncStatus = "My Books sent to Apple Watch."
        } catch {
            watchSyncStatus = "Watch sync failed: \(error.localizedDescription)"
        }
    }

    func syncWatchNow() async {
        refreshConnectionState()
        guard isPaired else { watchSyncStatus = "No Apple Watch is paired."; return }
        guard isWatchAppInstalled else {
            watchSyncStatus = "Install Voxglass on the paired Apple Watch first."
            return
        }
        guard let libraryStore, let watchProjectionStore else {
            watchSyncStatus = "The iPhone app is still starting."
            return
        }
        do {
            // Application context is the durable fallback; when the watch is
            // reachable, send the same typed projection immediately as well.
            guard let message = try await makeTypedWatchMessage(
                libraryStore: libraryStore,
                projectionStore: watchProjectionStore
            ) else { return }
            try session.updateApplicationContext(message)
            lastWatchSyncDate = Date()
            watchSyncStatus = isReachable
                ? "Apple Watch sync sent."
                : "Apple Watch is not reachable; sync queued."
            if isReachable {
                session.sendMessage(
                    message,
                    replyHandler: { [weak self] _ in
                        Task { @MainActor in self?.watchSyncStatus = "Apple Watch updated." }
                    },
                    errorHandler: { [weak self] error in
                        Task { @MainActor in self?.watchSyncStatus = "Watch sync failed: \(error.localizedDescription)" }
                    }
                )
                connectionToast = "Apple Watch connected"
            }
        } catch {
            watchSyncStatus = "Watch sync failed: \(error.localizedDescription)"
        }
    }

    private func makeTypedWatchMessage(
        libraryStore: LibraryStore,
        projectionStore: PhoneWatchProjectionStore,
        correlationID: UUID? = nil
    ) async throws -> [String: Any]? {
        let revision = try await projectionStore.nextRevision()
        var snapshot = PhoneWatchProjection.library(from: libraryStore.books, libraryID: watchLibraryID, revision: revision)
        if let playback = playbackCoordinator, let session = playback.currentSession {
            snapshot = PhoneWatchProjection.applyingResumePosition(
                bookID: WatchBookID(session.book.id.uuidString),
                chapterID: WatchChapterID(session.chapter.id.uuidString),
                position: playback.playhead,
                to: snapshot
            )
        }
        let data = try WatchProtocolEnvelope.encode(
            kind: .librarySnapshot,
            payload: snapshot,
            libraryID: watchLibraryID,
            revision: revision,
            correlationID: correlationID
        )
        return WatchProtocolEnvelope.dictionary(for: data)
    }

    /// Persists the iPhone-owned desired root before any bytes are sent. Local
    /// imports and already-cached files are transferred directly; remote sources
    /// remain resumable until the existing phone cache has materialized them.
    func requestTypedWatchDownload(bookID: UUID) async {
        guard let libraryStore, let watchProjectionStore, let book = libraryStore.books.first(where: { $0.book.id == bookID }) else { return }
        let revision = (try? await watchProjectionStore.nextRevision()) ?? 0
        let plan = PhoneWatchDownloadPlanner.plan(for: book, revision: revision)
        do {
            try await watchProjectionStore.setDesiredRoot(plan.manifest)
            let manifest = try WatchProtocolEnvelope.encode(kind: .bookManifest, payload: plan.manifest, libraryID: watchLibraryID, revision: revision)
            session.transferUserInfo(WatchProtocolEnvelope.dictionary(for: manifest))
            for asset in plan.assets {
                guard let source = asset.sourceURL, source.isFileURL, FileManager.default.fileExists(atPath: source.path) else { continue }
                let envelope = try WatchProtocolEnvelope.encode(kind: .assetFile, payload: asset, libraryID: watchLibraryID, revision: revision)
                let metadata = WatchProtocolEnvelope.dictionary(for: envelope).merging(["watchAsset": true], uniquingKeysWith: { _, new in new })
                session.transferFile(source, metadata: metadata)
            }
        } catch {
            try? await watchProjectionStore.setDesired(.failed("preparation-failed"), for: plan.bookID)
        }
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
        totalChapterCount: Int? = nil
    ) -> WCSessionFileTransfer {
        var metadata: [String: Any] = ["chapterKey": chapterKey]
        if let bookID { metadata["bookID"] = bookID.uuidString }
        if let chapterFilename { metadata["chapterFilename"] = chapterFilename }
        if let totalChapterCount { metadata["totalChapterCount"] = totalChapterCount }
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
            case WatchPhoneAction.requestLibrary:
                return try WatchPhoneMessageCodec.reply(await makeLibrarySnapshot(refresh: true))

            case WatchPhoneAction.requestPlaybackState:
                return try WatchPhoneMessageCodec.reply(playbackState(accepted: true))

            case WatchPhoneAction.searchLibriVox:
                let request = try WatchPhoneMessageCodec.payload(WatchPhoneSearchRequest.self, from: message)
                let results = try await client.searchLibriVox(
                    query: request.query,
                    rows: max(1, min(request.limit, 25))
                )
                let filtered = results.filter(\.isStrictLibriVoxCatalogCandidate)
                return try WatchPhoneMessageCodec.reply(WatchPhoneSearchResponse(results: filtered))

            case WatchPhoneAction.playBook:
                let request = try WatchPhoneMessageCodec.payload(WatchPhonePlayBookRequest.self, from: message)
                let state = await playBook(bookID: request.bookID, chapterID: request.chapterID)
                return try WatchPhoneMessageCodec.reply(state)

            case WatchPhoneAction.playRemote:
                let request = try WatchPhoneMessageCodec.payload(WatchPhonePlayRemoteRequest.self, from: message)
                let state = await importAndPlay(identifier: request.identifier)
                return try WatchPhoneMessageCodec.reply(state)

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

    private func makeLibrarySnapshot(refresh: Bool) async -> WatchPhoneLibrarySnapshot {
        if refresh {
            await libraryStore?.refresh()
        }
        return WatchPhoneLibrarySnapshot(
            books: libraryStore?.books ?? [],
            playbackState: playbackState(accepted: true)
        )
    }

    private func playBook(bookID: UUID, chapterID: UUID?) async -> WatchPhonePlaybackState {
        guard let libraryStore, let playbackCoordinator else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: "The iPhone app is still starting.")
        }

        await libraryStore.refresh()
        guard let book = libraryStore.books.first(where: { $0.book.id == bookID }) else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: "This book is not in My Books on the iPhone.")
        }

        let chapter = chapterID.flatMap { id in
            book.chapters.first { $0.id == id }
        }
        await playbackCoordinator.play(book, chapter: chapter)
        await publishLibrarySnapshot()
        return playbackState(
            accepted: playbackCoordinator.currentSession?.book.id == bookID
                && playbackCoordinator.playbackPhase == .playing
        )
    }

    private func importAndPlay(identifier: String) async -> WatchPhonePlaybackState {
        guard let libraryStore, let playbackCoordinator else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: "The iPhone app is still starting.")
        }

        do {
            let metadata = try await client.metadata(for: identifier)
            let sourceKind: SourceKind = metadata.sourceKind == .librivox ? .librivox : .internetArchive
            guard let book = await libraryStore.importInternetArchiveItem(metadata, sourceKind: sourceKind) else {
                return WatchPhonePlaybackState(
                    accepted: false,
                    errorMessage: libraryStore.importError ?? "The iPhone could not add this book."
                )
            }
            await playbackCoordinator.play(book)
            await publishLibrarySnapshot()
            return playbackState(
                accepted: playbackCoordinator.currentSession?.book.id == book.book.id
                    && playbackCoordinator.playbackPhase == .playing
            )
        } catch {
            return WatchPhonePlaybackState(accepted: false, errorMessage: error.localizedDescription)
        }
    }

    private func handlePlaybackCommand(_ request: WatchPhonePlaybackCommandRequest) async -> WatchPhonePlaybackState {
        guard let playbackCoordinator else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: "The iPhone app is still starting.")
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
            return WatchPhonePlaybackState(accepted: false, errorMessage: "The iPhone app is still starting.")
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
            let contentKey = message["contentKey"] as? String ?? ""
            let chapterKey = message["chapterKey"] as? String ?? ""
            _ = await findAndSendChapter(contentKey: contentKey, chapterKey: chapterKey)
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
        lastWatchSyncDate = Date()
        watchSyncStatus = "Watch storage updated."
    }

    private func applyWatchAcknowledgement(_ acknowledgement: WatchManifestAcknowledgement) {
        guard let id = UUID(uuidString: acknowledgement.bookID.rawValue) else { return }
        let state: WatchTransferState = acknowledgement.complete ? .available : .failed
        let info = WatchBookStorageInfo(
            state: state,
            byteCount: acknowledgement.installedBytes,
            chapterCount: 0,
            completeChapterCount: acknowledgement.complete ? 1 : 0,
            totalChapterCount: 0
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

    /// Resolves a requested chapter through the cache store and ships its blob to
    /// the watch. Returns false (without touching the network) when the blob is
    /// absent or incomplete, so the watch falls back to its own radio download.
    private func findAndSendChapter(contentKey: String, chapterKey: String) async -> Bool {
        guard let fileURL = await WatchChapterTransfer.resolvedFileURL(
            cacheStore: AudioCache.shared,
            chapterKey: chapterKey
        ) else {
            return false
        }
        transferChapterFile(at: fileURL, chapterKey: chapterKey)
        return true
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
        guard isWatchAppInstalled else {
            return .failed("The Voxglass app isn't installed on your Apple Watch.")
        }
        guard let offlineManager else {
            return .failed("The iPhone app is still starting.")
        }

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

        isTransferringToWatch = true
        defer { isTransferringToWatch = false }

        func fail(_ message: String) -> WatchTransferStart {
            var storage = watchStorageSnapshot?.books ?? [:]
            storage[book.book.id] = WatchBookStorageInfo(
                state: .failed,
                byteCount: 0,
                chapterCount: 0,
                completeChapterCount: 0,
                totalChapterCount: book.chapters.count
            )
            applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))
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
                    return fail("The book stopped downloading to the iPhone before it finished.")
                }
                try? await Task.sleep(for: .milliseconds(500))
                state = offlineManager.state(for: book.book.id)
            }
            if state == .failed {
                return fail("The book couldn't be downloaded on the iPhone.")
            }
        }

        // Resolve every chapter's local file BEFORE sending anything. The
        // watch is told the book's full chapter count up front and can only
        // ever acknowledge once every one of them has arrived — silently
        // sending fewer (the original version of this skipped whichever
        // chapters weren't resolvable yet) guarantees a transfer that can
        // never complete, no matter how patient anything downstream is.
        let chapterFilename = { (chapter: Chapter) in "\(chapter.id.uuidString).audio" }
        var resolvedChapterFiles: [(chapter: Chapter, key: String, url: URL)] = []
        for chapter in book.chapters {
            guard let key = ChapterAudioIdentity.cacheKey(for: chapter) else {
                return fail("A chapter's audio file couldn't be identified.")
            }
            if let localURL = localOnDiskURL(for: chapter) {
                resolvedChapterFiles.append((chapter, key, localURL))
                continue
            }
            guard let fileURL = await WatchChapterTransfer.resolvedFileURL(
                cacheStore: AudioCache.shared,
                chapterKey: key
            ) else {
                return fail("Not every chapter has finished downloading to the iPhone yet.")
            }
            resolvedChapterFiles.append((chapter, key, fileURL))
        }
        guard !resolvedChapterFiles.isEmpty else {
            return fail("No chapters were ready to transfer.")
        }

        let fileTransfers = resolvedChapterFiles.map { chapter, key, url in
            transferChapterFile(
                at: url,
                chapterKey: key,
                bookID: book.book.id,
                chapterFilename: chapterFilename(chapter),
                totalChapterCount: book.chapters.count
            )
        }
        await requestTypedWatchDownload(bookID: book.book.id)
        watchSyncStatus = "\(book.book.title) queued for Apple Watch."
        watchTransferSupervisor(for: book.book.id, fileTransfers: fileTransfers)
        return .started
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
        // long time with no single stretch of true silence. 120s of zero
        // measured progress is a genuine stall; 90 minutes is a last-resort
        // cap for a runaway task, not an expected real-world duration.
        stallTimeout: TimeInterval = 120,
        absoluteTimeout: TimeInterval = 90 * 60
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
        try? await watchProjectionStore.remove(bookID: id)
        var storage = watchStorageSnapshot?.books ?? [:]
        storage.removeValue(forKey: bookID)
        applyWatchStorageSnapshot(WatchStorageSnapshot(books: storage))
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        if let data = try? WatchProtocolEnvelope.encode(
            kind: .removeBookDownload,
            payload: WatchManifest(bookID: id, revision: 0, requiredChapterIDs: []),
            libraryID: watchLibraryID
        ) {
            session.transferUserInfo(WatchProtocolEnvelope.dictionary(for: data))
        }
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
                connectionToast = "Apple Watch connected"
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
                connectionToast = "Apple Watch connected"
            }
            if reachable {
                await publishLibrarySnapshot()
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
            await handleReceivedMessageWithoutReply(box.value)
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
        case .watchManifest:
            guard let acknowledgement = try? envelope.decodePayload(WatchManifestAcknowledgement.self),
                  let store = watchProjectionStore else { return }
            try? await store.acknowledge(acknowledgement)
            applyWatchAcknowledgement(acknowledgement)
        case .setBookDownload:
            guard let manifest = try? envelope.decodePayload(WatchManifest.self),
                  let id = UUID(uuidString: manifest.bookID.rawValue) else { return }
            await requestTypedWatchDownload(bookID: id)
        case .reconcileRequest, .hello:
            await publishTypedWatchProjection()
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
                watchSyncStatus = "My Books sent to Apple Watch."
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
