import AVFoundation
import Foundation
import MediaPlayer
import VoxglassWatchCore
import VoxglassWatchProtocol

@MainActor
final class WatchPlaybackEngine {
    var onSnapshot: ((WatchPlaybackSnapshot) -> Void)?
    var onBookChanged: ((WatchBookDTO?) -> Void)?
    var streamingAllowed: () -> Bool = { false }

    private(set) var snapshot = WatchPlaybackSnapshot()
    private(set) var book: WatchBookDTO?
    private let downloadsRoot: URL
    private let positionStore: WatchPlaybackPositionStore
    private let smokeMode: Bool
    private let smokeFailure: Bool
    private var player: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var periodicObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var playerNotificationObservers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var token = 0
    private var assetOffset: TimeInterval = 0
    private var lastPersistedSecond = -1

    init(root: URL? = nil, smokeMode: Bool = false, smokeFailure: Bool = false) {
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        downloadsRoot = support.appendingPathComponent("DownloadedBooks", isDirectory: true)
        positionStore = WatchPlaybackPositionStore(url: support.appendingPathComponent("watch-playback-positions.json"))
        self.smokeMode = smokeMode
        self.smokeFailure = smokeFailure
        if !smokeMode {
            installNotifications()
            installRemoteCommands()
        }
    }

    isolated deinit {
        if let periodicObserver { player?.removeTimeObserver(periodicObserver) }
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in playerNotificationObservers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in commandTargets { command.removeTarget(target) }
    }

    func play(_ book: WatchBookDTO, chapterIndex: Int, allowsStreaming: Bool) {
        guard book.chapters.indices.contains(chapterIndex) else {
            publishFailure("No playable chapter is available.")
            return
        }
        token += 1
        let currentToken = token
        self.book = book
        onBookChanged?(book)
        let chapter = book.chapters[chapterIndex]
        snapshot = WatchPlaybackReducer.preparing(
            bookID: book.id,
            chapter: chapter,
            chapterCount: book.chapters.count,
            position: 0,
            token: currentToken
        )
        publish()

        Task { [weak self] in
            guard let self else { return }
            let localPosition = await positionStore.position(bookID: book.id, chapterID: chapter.id)
            // The first time a book is opened on the watch, its local store is
            // empty. Use the phone's savepoint in that case; later watch-local
            // progress remains authoritative for a reopened book.
            let savedPosition = localPosition > 0 ? localPosition : max(0, chapter.resumePosition ?? 0)
            guard currentToken == token else { return }
            snapshot.position = savedPosition
            if smokeMode {
                if smokeFailure {
                    publish(.failed("Download this chapter or reconnect to stream it."), token: currentToken)
                    return
                }
                snapshot.sourceKind = .downloaded
                publish(.playing, token: currentToken)
                startSmokeClock(token: currentToken)
                return
            }
            do {
                let source = try WatchPlaybackSourceResolver.resolve(
                    bookID: book.id,
                    chapter: chapter,
                    downloadsRoot: downloadsRoot,
                    allowsStreaming: allowsStreaming
                )
                assetOffset = source.assetOffset
                snapshot.sourceKind = source.kind
                publish(.waitingForOutput, token: currentToken)
                try await activateAudioSession()
                guard currentToken == token else { return }
                installPlayer(url: source.url, resumePosition: savedPosition, token: currentToken)
            } catch WatchPlaybackResolutionError.chapterUnavailable {
                publish(.failed("Download this chapter or reconnect to stream it."), token: currentToken)
            } catch {
                publish(.failed(audioErrorMessage(error)), token: currentToken)
            }
        }
    }

    func togglePlayPause() {
        switch snapshot.phase {
        case .playing, .buffering:
            player?.pause()
            publish(.paused, token: token)
            persistPosition()
        case .paused, .ended, .failed:
            if smokeMode {
                publish(.playing, token: token)
            } else if player != nil {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await activateAudioSession()
                        player?.play()
                    } catch {
                        publish(.failed(audioErrorMessage(error)), token: token)
                    }
                }
            } else {
                retry()
            }
        case .idle, .preparing, .waitingForOutput:
            break
        }
    }

    func retry() {
        guard let book, snapshot.chapterIndex >= 0 else { return }
        play(book, chapterIndex: snapshot.chapterIndex, allowsStreaming: streamingAllowed())
    }

    func nextChapter() { moveChapter(by: 1) }
    func previousChapter() { moveChapter(by: -1) }

    func seek(to position: TimeInterval) {
        let value = position.isFinite ? min(max(0, position), snapshot.duration) : 0
        snapshot.position = value
        if !smokeMode {
            player?.seek(to: CMTime(seconds: assetOffset + value, preferredTimescale: 600))
        }
        persistPosition()
        publish()
    }

    func persistPlaybackPosition() { persistPosition() }

    private func moveChapter(by amount: Int) {
        guard let book else { return }
        let destination = snapshot.chapterIndex + amount
        guard book.chapters.indices.contains(destination) else { return }
        persistPosition()
        play(book, chapterIndex: destination, allowsStreaming: streamingAllowed())
    }

    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        try await session.activate(options: [])
    }

    private func installPlayer(url: URL, resumePosition: TimeInterval, token currentToken: Int) {
        removePlayerObservers()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        playerItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, currentToken == self.token else { return }
                switch item.status {
                case .readyToPlay:
                    let target = self.assetOffset + resumePosition
                    if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) }
                    player.play()
                case .failed:
                    self.publish(.failed(item.error?.localizedDescription ?? "This chapter could not be played."), token: currentToken)
                case .unknown:
                    self.publish(.buffering, token: currentToken)
                @unknown default:
                    self.publish(.failed("This chapter could not be played."), token: currentToken)
                }
            }
        }
        playerStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, currentToken == self.token else { return }
                switch player.timeControlStatus {
                case .playing: self.publish(.playing, token: currentToken)
                case .paused: self.publish(.paused, token: currentToken)
                case .waitingToPlayAtSpecifiedRate: self.publish(.buffering, token: currentToken)
                @unknown default: self.publish(.buffering, token: currentToken)
                }
            }
        }
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, currentToken == self.token else { return }
                let itemDuration = player.currentItem?.duration.seconds ?? self.snapshot.duration
                let chapterPosition = max(0, time.seconds - self.assetOffset)
                let duration = self.snapshot.duration > 0 ? self.snapshot.duration : itemDuration
                self.publish(.time(position: chapterPosition, duration: duration), token: currentToken)
                let second = Int(chapterPosition)
                if second / 10 != self.lastPersistedSecond / 10 {
                    self.lastPersistedSecond = second
                    self.persistPosition()
                }
            }
        }
        let end = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.itemEnded(token: currentToken) } }
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "This chapter stopped unexpectedly."
            Task { @MainActor in self?.publish(.failed(message), token: currentToken) }
        }
        playerNotificationObservers.append(contentsOf: [end, failed])
    }

    private func itemEnded(token currentToken: Int) {
        guard currentToken == token else { return }
        persistPosition()
        if snapshot.canGoNext { nextChapter() } else { publish(.ended, token: currentToken) }
    }

    private func startSmokeClock(token currentToken: Int) {
        Task { [weak self] in
            while let self, currentToken == self.token {
                try? await Task.sleep(for: .seconds(1))
                guard currentToken == self.token else { return }
                guard self.snapshot.phase == .playing else { continue }
                self.publish(
                    .time(position: self.snapshot.position + 1, duration: self.snapshot.duration),
                    token: currentToken
                )
            }
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.handleInterruption(type: type, options: options) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleInterruption(type raw: UInt?, options rawOptions: UInt?) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            player?.pause()
            publish(.interruption, token: token)
            persistPosition()
        } else if let rawOptions,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
            Task { [weak self] in
                guard let self else { return }
                do { try await activateAudioSession(); player?.play() }
                catch { publish(.failed(audioErrorMessage(error)), token: token) }
            }
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        player?.pause()
        publish(.routeLost, token: token)
        persistPosition()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.nextTrackCommand) { [weak self] _ in self?.nextChapter(); return .success }
        add(center.previousTrackCommand) { [weak self] _ in self?.previousChapter(); return .success }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        let target = command.addTarget(handler: handler)
        commandTargets.append((command, target))
    }

    private func publish(_ event: WatchPlaybackEvent, token currentToken: Int) {
        snapshot = WatchPlaybackReducer.reduce(snapshot, event: event, token: currentToken)
        publish()
    }

    private func publish() {
        updateNowPlaying()
        onSnapshot?(snapshot)
    }

    private func publishFailure(_ message: String) {
        token += 1
        snapshot = WatchPlaybackSnapshot(phase: .failed(message), eventToken: token)
        publish()
    }

    private func updateNowPlaying() {
        guard !smokeMode else { return }
        if case .failed = snapshot.phase {
            if MPNowPlayingInfoCenter.default().nowPlayingInfo != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        guard let book, let chapterID = snapshot.chapterID,
              book.chapters.indices.contains(snapshot.chapterIndex) else { return }
        let chapter = book.chapters[snapshot.chapterIndex]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author ?? "",
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isActuallyPlaying ? snapshot.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyChapterNumber: snapshot.chapterIndex,
            MPNowPlayingInfoPropertyChapterCount: snapshot.chapterCount,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "\(book.id.rawValue)|\(chapterID.rawValue)"
        ]
    }

    private func persistPosition() {
        guard let bookID = snapshot.bookID, let chapterID = snapshot.chapterID else { return }
        let position = snapshot.position
        Task { try? await positionStore.save(position, bookID: bookID, chapterID: chapterID) }
    }

    private func removePlayerObservers() {
        playerItemObservation = nil
        playerStatusObservation = nil
        if let periodicObserver { player?.removeTimeObserver(periodicObserver); self.periodicObserver = nil }
        for observer in playerNotificationObservers { NotificationCenter.default.removeObserver(observer) }
        playerNotificationObservers.removeAll()
        player?.pause()
        player = nil
    }

    private func audioErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain || nsError.domain == NSOSStatusErrorDomain {
            return "Connect Bluetooth headphones, then try again."
        }
        return "Playback failed: \(error.localizedDescription)"
    }
}
