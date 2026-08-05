import Foundation
import WatchConnectivity
import VoxglassCore

@MainActor
final class PhoneAudioRelay: NSObject, ObservableObject {
    static let shared = PhoneAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var watchStorageSnapshot: WatchStorageSnapshot?
    @Published private(set) var isTransferringToWatch = false
    @Published var watchTransferError: String?

    private let session: WCSession
    private let client: InternetArchiveCatalogClient
    private weak var libraryStore: LibraryStore?
    private weak var playbackCoordinator: PlaybackCoordinator?
    private weak var offlineManager: OfflineDownloadManager?

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
    }

    func configure(
        libraryStore: LibraryStore,
        playbackCoordinator: PlaybackCoordinator,
        offlineManager: OfflineDownloadManager? = nil
    ) {
        self.libraryStore = libraryStore
        self.playbackCoordinator = playbackCoordinator
        self.offlineManager = offlineManager
        Task { await publishLibrarySnapshot() }
    }

    func publishLibrarySnapshot() async {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        do {
            let snapshot = await makeLibrarySnapshot(refresh: false)
            let context = try WatchPhoneMessageCodec.message(
                action: WatchPhoneAction.requestLibrary,
                payload: snapshot
            )
            try session.updateApplicationContext(context)
        } catch {
            // The next explicit watch request will fetch a fresh snapshot.
        }
    }

    func transferChapterFile(at url: URL, chapterKey: String) {
        session.transferFile(url, metadata: ["chapterKey": chapterKey])
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
    }

    /// Resolves a requested chapter through the cache store and ships its blob to
    /// the watch. Returns false (without touching the network) when the blob is
    /// absent or incomplete, so the watch falls back to its own radio download.
    private func findAndSendChapter(contentKey: String, chapterKey: String) async -> Bool {
        guard let fileURL = await WatchChapterTransfer.resolvedFileURL(
            cacheStore: .shared,
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
    func transferBookToWatch(
        _ book: BookWithChapters,
        allowCellularOverride: Bool = false
    ) async -> WatchTransferStart {
        guard isWatchAppInstalled else {
            return .failed("The Voxglass app isn't installed on your Apple Watch.")
        }
        guard let offlineManager else {
            return .failed("The iPhone app is still starting.")
        }

        if offlineManager.state(for: book.book.id) != .cached {
            let decision = await offlineManager.makeAvailableOffline(
                book: book,
                isCellular: NetworkMonitor.shared.isCellular,
                allowCellularOverride: allowCellularOverride
            )
            guard decision == .start else { return .needsCellularConfirmation }
        }

        isTransferringToWatch = true
        defer { isTransferringToWatch = false }

        // Wait for the phone-side download to complete before transferring.
        let deadline = Date().addingTimeInterval(180)
        var state = offlineManager.state(for: book.book.id)
        while Date() < deadline {
            if case .downloading = state {
                try? await Task.sleep(for: .milliseconds(500))
                state = offlineManager.state(for: book.book.id)
                continue
            }
            break
        }
        if state == .failed {
            return .failed("The book couldn't be downloaded on the iPhone.")
        }

        var transferred = 0
        for chapter in book.chapters {
            guard let key = ChapterAudioIdentity.cacheKey(for: chapter) else { continue }
            guard let fileURL = await WatchChapterTransfer.resolvedFileURL(
                cacheStore: .shared,
                chapterKey: key
            ) else { continue }
            transferChapterFile(at: fileURL, chapterKey: key)
            transferred += 1
        }
        if transferred == 0 {
            return .failed("No chapters were ready to transfer.")
        }
        return .started
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
            productionTransport?.updateReachability(reachable: session.isReachable, activated: activationState == .activated)
            await publishLibrarySnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
            productionTransport?.updateReachability(reachable: session.isReachable, activated: session.activationState == .activated)
            if session.isReachable {
                await publishLibrarySnapshot()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            forwardProduction(message)
            await handleReceivedMessageWithoutReply(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor in
            forwardProduction(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            forwardProduction(applicationContext)
            if WatchPhoneMessageCodec.action(from: applicationContext) == WatchPhoneAction.reportWatchStorage,
               let snapshot = try? WatchPhoneMessageCodec.payload(WatchStorageSnapshot.self, from: applicationContext) {
                applyWatchStorageSnapshot(snapshot)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            if WatchPhoneMessageCodec.action(from: message) == ProductionTransportAction.requestRefresh {
                // The watch asked the phone to re-push its projection; acknowledge.
                forwardProduction(message)
                replyHandler(["received": true])
                return
            }
            replyHandler(await reply(for: message))
        }
    }
}
