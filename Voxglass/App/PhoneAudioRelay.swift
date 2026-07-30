import Foundation
import WatchConnectivity
import VoxglassCore

@MainActor
final class PhoneAudioRelay: NSObject, ObservableObject {
    static let shared = PhoneAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false

    private let session: WCSession
    private let client: InternetArchiveCatalogClient
    private weak var libraryStore: LibraryStore?
    private weak var playbackCoordinator: PlaybackCoordinator?

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

    func configure(libraryStore: LibraryStore, playbackCoordinator: PlaybackCoordinator) {
        self.libraryStore = libraryStore
        self.playbackCoordinator = playbackCoordinator
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

    private func handleReceivedMessageWithoutReply(_ message: [String: Any]) async {
        guard let action = message["action"] as? String else { return }
        switch action {
        case "requestChapterFile":
            let contentKey = message["contentKey"] as? String ?? ""
            let chapterKey = message["chapterKey"] as? String ?? ""
            _ = await findAndSendChapter(contentKey: contentKey, chapterKey: chapterKey)
        default:
            break
        }
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

extension PhoneAudioRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            isWatchAppInstalled = session.isWatchAppInstalled
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
            await handleReceivedMessageWithoutReply(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            replyHandler(await reply(for: message))
        }
    }
}
