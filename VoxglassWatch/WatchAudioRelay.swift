import Foundation
import WatchConnectivity
import VoxglassCore

@MainActor
final class WatchAudioRelay: NSObject, ObservableObject {
    static let shared = WatchAudioRelay()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isCompanionAppInstalled: Bool = false
    @Published private(set) var librarySnapshot: WatchPhoneLibrarySnapshot?
    @Published private(set) var searchResults: [InternetArchiveSearchResult] = []
    @Published private(set) var playbackState: WatchPhonePlaybackState?
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var isSearching = false
    @Published private(set) var lastError: String?

    private let session: WCSession
    private let smokeMode: Bool
    var onFileReceived: ((URL, String) -> Void)?
    var onLibrarySnapshot: ((WatchPhoneLibrarySnapshot) -> Void)?
    var onPlaybackState: ((WatchPhonePlaybackState) -> Void)?

    override init() {
        smokeMode = Self.isSmokeModeEnabled
        guard WCSession.isSupported() else {
            session = WCSession.default
            super.init()
            if smokeMode {
                applySmokeLibrary()
            }
            return
        }
        session = WCSession.default
        super.init()
        session.delegate = self
        session.activate()
        if smokeMode {
            applySmokeLibrary()
        }
    }

    private static var isSmokeModeEnabled: Bool {
        let key = "VOXGLASS_WATCH_SMOKE_ALICE"
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment[key] == "1"
            || processInfo.arguments.contains("-\(key)")
            || UserDefaults.standard.bool(forKey: key)
    }

    func requestLibrarySnapshot() async -> WatchPhoneLibrarySnapshot? {
        if smokeMode {
            applySmokeLibrary()
            return librarySnapshot
        }

        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        do {
            let snapshot: WatchPhoneLibrarySnapshot = try await request(
                action: WatchPhoneAction.requestLibrary,
                payload: WatchPhoneEmptyPayload()
            )
            applyLibrarySnapshot(snapshot)
            return snapshot
        } catch {
            lastError = error.localizedDescription
            return librarySnapshot
        }
    }

    func requestPlaybackState() async -> WatchPhonePlaybackState? {
        if smokeMode {
            return playbackState
        }

        do {
            let state: WatchPhonePlaybackState = try await request(
                action: WatchPhoneAction.requestPlaybackState,
                payload: WatchPhoneEmptyPayload()
            )
            applyPlaybackState(state)
            return state
        } catch {
            lastError = error.localizedDescription
            return playbackState
        }
    }

    func searchLibriVox(_ query: String) async -> [InternetArchiveSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return []
        }

        if smokeMode {
            let alice = smokeSearchResult()
            searchResults = [alice]
            return [alice]
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let response: WatchPhoneSearchResponse = try await request(
                action: WatchPhoneAction.searchLibriVox,
                payload: WatchPhoneSearchRequest(query: trimmed)
            )
            searchResults = response.results
            return response.results
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func playBook(_ book: BookWithChapters, chapter: Chapter? = nil) async -> WatchPhonePlaybackState {
        if smokeMode {
            let target = chapter ?? book.chapters.first
            let state = WatchPhonePlaybackState(
                accepted: target != nil,
                session: target.map {
                    PlaybackSession(
                        book: book.book,
                        chapters: book.chapters,
                        chapter: $0,
                        position: 0,
                        duration: $0.duration,
                        isPlaying: true
                    )
                },
                errorMessage: target == nil ? "No playable chapters." : nil
            )
            applyPlaybackState(state)
            return state
        }

        do {
            let state: WatchPhonePlaybackState = try await request(
                action: WatchPhoneAction.playBook,
                payload: WatchPhonePlayBookRequest(bookID: book.book.id, chapterID: chapter?.id)
            )
            applyPlaybackState(state)
            return state
        } catch {
            let state = WatchPhonePlaybackState(accepted: false, errorMessage: error.localizedDescription)
            applyPlaybackState(state)
            return state
        }
    }

    func playRemote(identifier: String) async -> WatchPhonePlaybackState {
        if smokeMode {
            return await playBook(WatchPhoneSmokeFixtures.aliceInWonderland())
        }

        do {
            let state: WatchPhonePlaybackState = try await request(
                action: WatchPhoneAction.playRemote,
                payload: WatchPhonePlayRemoteRequest(identifier: identifier)
            )
            applyPlaybackState(state)
            return state
        } catch {
            let state = WatchPhonePlaybackState(accepted: false, errorMessage: error.localizedDescription)
            applyPlaybackState(state)
            return state
        }
    }

    func sendPlaybackCommand(
        _ command: WatchPhonePlaybackCommand,
        seconds: TimeInterval? = nil
    ) async -> WatchPhonePlaybackState {
        if smokeMode {
            let state = smokePlaybackState(after: command, seconds: seconds)
            applyPlaybackState(state)
            return state
        }

        do {
            let state: WatchPhonePlaybackState = try await request(
                action: WatchPhoneAction.playbackCommand,
                payload: WatchPhonePlaybackCommandRequest(command: command, seconds: seconds)
            )
            applyPlaybackState(state)
            return state
        } catch {
            let state = WatchPhonePlaybackState(accepted: false, errorMessage: error.localizedDescription)
            applyPlaybackState(state)
            return state
        }
    }

    func requestChapter(_ contentKey: String, chapterKey: String) {
        let message: [String: Any] = [
            "action": "requestChapterFile",
            "contentKey": contentKey,
            "chapterKey": chapterKey
        ]
        session.sendMessage(message, replyHandler: nil)
    }

    private func request<Response: Decodable, Payload: Encodable>(
        action: String,
        payload: Payload
    ) async throws -> Response {
        guard WCSession.isSupported() else { throw WatchRelayError.unsupported }
        guard session.activationState == .activated else { throw WatchRelayError.notActivated }
        guard session.isReachable else { throw WatchRelayError.phoneUnreachable }

        let message = try WatchPhoneMessageCodec.message(action: action, payload: payload)
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                message,
                replyHandler: { reply in
                    do {
                        let decoded = try WatchPhoneMessageCodec.replyPayload(Response.self, from: reply)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                },
                errorHandler: { error in
                    continuation.resume(throwing: error)
                }
            )
        }
    }

    private func applyLibrarySnapshot(_ snapshot: WatchPhoneLibrarySnapshot) {
        librarySnapshot = snapshot
        if let state = snapshot.playbackState {
            applyPlaybackState(state)
        }
        onLibrarySnapshot?(snapshot)
        lastError = nil
    }

    private func applyPlaybackState(_ state: WatchPhonePlaybackState) {
        playbackState = state
        lastError = state.errorMessage
        onPlaybackState?(state)
    }

    private func applySmokeLibrary() {
        let alice = WatchPhoneSmokeFixtures.aliceInWonderland()
        let snapshot = WatchPhoneLibrarySnapshot(
            books: [alice],
            playbackState: WatchPhonePlaybackState(accepted: true)
        )
        applyLibrarySnapshot(snapshot)
    }

    private func smokeSearchResult() -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: WatchPhoneSmokeFixtures.aliceIdentifier,
            title: WatchPhoneSmokeFixtures.aliceTitle,
            creators: ["Lewis Carroll"],
            description: "A public-domain LibriVox recording.",
            collections: ["librivoxaudio"],
            downloads: nil,
            date: "2006",
            languages: ["English"],
            subjects: ["Children's Fiction", "Fantastic Fiction"]
        )
    }

    private func smokePlaybackState(
        after command: WatchPhonePlaybackCommand,
        seconds: TimeInterval?
    ) -> WatchPhonePlaybackState {
        guard var session = playbackState?.session else {
            return WatchPhonePlaybackState(accepted: false, errorMessage: "No active playback session.")
        }

        switch command {
        case .togglePlayPause:
            session.isPlaying.toggle()
        case .pause:
            session.isPlaying = false
        case .skipBackward:
            session.position = max(0, session.position - (seconds ?? 15))
        case .skipForward:
            session.position = PlaybackMath.clampedPosition(session.position + (seconds ?? 30), duration: session.duration)
        case .previousChapter:
            if let previous = WatchChapterNavigation.previous(before: session.chapter.id, in: session.chapters) {
                session.chapter = previous
                session.position = 0
                session.duration = previous.duration
            }
        case .nextChapter:
            if let next = WatchChapterNavigation.next(after: session.chapter.id, in: session.chapters) {
                session.chapter = next
                session.position = 0
                session.duration = next.duration
            }
        }

        return WatchPhonePlaybackState(accepted: true, session: session)
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        let metadata = file.metadata
        let chapterKey = (metadata?["chapterKey"] as? String) ?? file.fileURL.lastPathComponent
        onFileReceived?(file.fileURL, chapterKey)
    }

    private func handleReceivedMessage(_ message: [String: Any]) {
        guard let action = WatchPhoneMessageCodec.action(from: message) else { return }
        switch action {
        case WatchPhoneAction.requestLibrary:
            if let snapshot = try? WatchPhoneMessageCodec.payload(WatchPhoneLibrarySnapshot.self, from: message) {
                applyLibrarySnapshot(snapshot)
            }
        case WatchPhoneAction.requestPlaybackState:
            if let state = try? WatchPhoneMessageCodec.payload(WatchPhonePlaybackState.self, from: message) {
                applyPlaybackState(state)
            }
        case "transferComplete":
            break
        case "transferFailed":
            break
        default:
            break
        }
    }
}

extension WatchAudioRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            isCompanionAppInstalled = session.isCompanionAppInstalled
            if let context = try? WatchPhoneMessageCodec.payload(
                WatchPhoneLibrarySnapshot.self,
                from: session.receivedApplicationContext
            ) {
                applyLibrarySnapshot(context)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            if let snapshot = try? WatchPhoneMessageCodec.payload(
                WatchPhoneLibrarySnapshot.self,
                from: applicationContext
            ) {
                applyLibrarySnapshot(snapshot)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            handleReceivedFile(file)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            handleReceivedMessage(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handleReceivedMessage(message)
            replyHandler(["received": true])
        }
    }
}

private enum WatchRelayError: Error, LocalizedError {
    case unsupported
    case notActivated
    case phoneUnreachable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "WatchConnectivity is not available."
        case .notActivated:
            "The iPhone connection is still starting."
        case .phoneUnreachable:
            "Open Voxglass on your iPhone and keep it nearby."
        }
    }
}
