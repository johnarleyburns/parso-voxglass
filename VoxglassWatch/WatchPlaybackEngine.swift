import AVFoundation
import Foundation
import MediaPlayer
import WatchKit
import VoxglassWatchCore
import VoxglassWatchProtocol

/// The watch's spoken-audio engine (watch redesign §5–§6). One `AVPlayer` per chapter, with:
/// 15/30 s skips, per-book speed with pitch correction, a sleep timer with a 10 s fade, resume
/// rewind, classified failures with diagnostic codes (Problem Cards S1–S3), and AirPods presses
/// mapped to time skips instead of chapter jumps.
@MainActor
final class WatchPlaybackEngine {
    var onSnapshot: ((WatchPlaybackSnapshot) -> Void)?
    var onBookChanged: ((WatchBookDTO?) -> Void)?
    /// Fired when the sleep timer arms, ticks or ends (`nil`), so the UI can show its chip.
    var onSleepChange: ((WatchSleepTimer?, TimeInterval?) -> Void)?
    var streamingAllowed: () -> Bool = { false }

    private(set) var snapshot = WatchPlaybackSnapshot()
    private(set) var book: WatchBookDTO?
    private(set) var sleepTimer: WatchSleepTimer?
    private let downloadsRoot: URL
    private let positionStore: WatchPlaybackPositionStore
    private let speedStore: WatchSpeedStore
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
    private var didBecomeReadyToken: Int?
    private var assetOffset: TimeInterval = 0
    private var lastPersistedSecond = -1
    private var pausedAt: Date?
    private var sleepTask: Task<Void, Never>?
    private(set) var volume: Double = 1

    init(root: URL? = nil, smokeMode: Bool = false, smokeFailure: Bool = false) {
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        downloadsRoot = support.appendingPathComponent("DownloadedBooks", isDirectory: true)
        positionStore = WatchPlaybackPositionStore(url: support.appendingPathComponent("watch-playback-positions.json"))
        speedStore = WatchSpeedStore(url: support.appendingPathComponent("watch-playback-speeds.json"))
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
        sleepTask?.cancel()
    }

    // MARK: - Transport

    func play(_ book: WatchBookDTO, chapterIndex: Int, allowsStreaming: Bool) {
        guard book.chapters.indices.contains(chapterIndex) else {
            publishFailure(String(localized: "No playable chapter is available."))
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
            let rate = await speedStore.rate(for: book.id)
            // The first time a book is opened on the watch, its local store is
            // empty. Use the phone's savepoint in that case; later watch-local
            // progress remains authoritative for a reopened book.
            let saved = localPosition > 0 ? localPosition : max(0, chapter.resumePosition ?? 0)
            let savedPosition = WatchResumeRewind.position(saved, pausedAt: pausedAt, now: Date())
            pausedAt = nil
            guard currentToken == token else { return }
            snapshot.position = savedPosition
            publish(.rate(rate), token: currentToken)
            if smokeMode {
                if smokeFailure {
                    publish(.problem(.chapterUnavailable,
                                     message: String(localized: "Download this chapter or reconnect to stream it."),
                                     code: "chapterUnavailable"), token: currentToken)
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
                installPlayer(url: source.url, kind: source.kind, resumePosition: savedPosition, token: currentToken)
            } catch WatchPlaybackResolutionError.chapterUnavailable {
                publish(.problem(.chapterUnavailable,
                                 message: String(localized: "Download this chapter or reconnect to stream it."),
                                 code: "chapterUnavailable"), token: currentToken)
            } catch {
                publishActivationFailure(error, token: currentToken)
            }
        }
    }

    func togglePlayPause() {
        switch snapshot.phase {
        case .playing, .buffering:
            player?.pause()
            pausedAt = Date()
            publish(.paused, token: token)
            persistPosition()
        case .paused, .ended, .failed:
            if smokeMode {
                publish(.playing, token: token)
            } else if let player {
                let rewound = WatchResumeRewind.position(snapshot.position, pausedAt: pausedAt, now: Date())
                pausedAt = nil
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await activateAudioSession()
                        if rewound < snapshot.position { seek(to: rewound) }
                        player.playImmediately(atRate: Float(snapshot.rate))
                    } catch {
                        publishActivationFailure(error, token: token)
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

    func jump(toChapter index: Int) {
        guard let book, book.chapters.indices.contains(index) else { return }
        persistPosition()
        play(book, chapterIndex: index, allowsStreaming: streamingAllowed())
    }

    /// §5 P1 — skip back 15 s / forward 30 s within the chapter.
    func skip(by delta: TimeInterval) {
        seek(to: WatchSkip.position(from: snapshot.position, by: delta, duration: snapshot.duration))
    }

    func seek(to position: TimeInterval) {
        let value = position.isFinite ? min(max(0, position), snapshot.duration) : 0
        snapshot.position = value
        if !smokeMode {
            player?.seek(to: CMTime(seconds: assetOffset + value, preferredTimescale: 600))
        }
        persistPosition()
        publish()
    }

    /// §5 C2 — apply a speed now, remember it for this book, keep pitch natural.
    func setRate(_ rate: Double) {
        let normalized = WatchSpeed.normalized(rate)
        if let player {
            player.defaultRate = Float(normalized)
            if player.timeControlStatus != .paused { player.rate = Float(normalized) }
        }
        publish(.rate(normalized), token: token)
        if let bookID = snapshot.bookID {
            Task { try? await speedStore.setRate(normalized, for: bookID) }
        }
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        applyVolume()
    }

    func persistPlaybackPosition() { persistPosition() }

    // MARK: - Sleep timer (§5 C3)

    func setSleepTimer(_ mode: WatchSleepTimer.Mode?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let mode else {
            sleepTimer = nil
            applyVolume()
            onSleepChange?(nil, nil)
            return
        }
        let timer = WatchSleepTimer(mode: mode, armedAt: Date())
        sleepTimer = timer
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let timer = self.sleepTimer else { return }
                let remaining = timer.remaining(at: Date(),
                                                chapterRemaining: max(0, self.snapshot.duration - self.snapshot.position),
                                                rate: self.snapshot.rate)
                self.onSleepChange?(timer, remaining)
                self.applyVolume(fade: WatchSleepTimer.fadeMultiplier(remaining: remaining))
                if remaining <= 0 {
                    self.sleepFired()
                    return
                }
                try? await Task.sleep(for: .seconds(remaining < WatchSleepTimer.fadeSeconds + 1 ? 0.5 : 1))
            }
        }
    }

    private func sleepFired() {
        sleepTask = nil
        sleepTimer = nil
        if snapshot.isActuallyPlaying || snapshot.phase == .buffering { togglePlayPause() }
        applyVolume()
        persistPosition()
        WKInterfaceDevice.current().play(.stop)
        onSleepChange?(nil, nil)
    }

    private func applyVolume(fade: Double = 1) {
        player?.volume = Float(volume * fade)
    }

    // MARK: - Internals

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

    private func installPlayer(url: URL, kind: WatchPlaybackSourceKind, resumePosition: TimeInterval,
                               token currentToken: Int) {
        removePlayerObservers()
        let item = AVPlayerItem(url: url)
        // Natural-sounding speech at any speed (§5 C2).
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        // A downloaded chapter is a complete local file: there is no network buffer to protect, and
        // the default waiting behaviour left playback parked in `.waitingToPlayAtSpecifiedRate`
        // ("Playback stalled") on device. Streams keep the default.
        player.automaticallyWaitsToMinimizeStalling = kind == .stream
        player.defaultRate = Float(snapshot.rate)
        self.player = player
        applyVolume()
        didBecomeReadyToken = nil

        playerItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, currentToken == self.token else { return }
                switch item.status {
                case .readyToPlay:
                    self.didBecomeReadyToken = currentToken
                    let target = self.assetOffset + resumePosition
                    if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) }
                    // `activate()` succeeding is watchOS's statement that a long-form route was
                    // chosen; an empty `currentRoute.outputs` snapshot at this instant is not a
                    // failure (gating on it refused playback with AirPods connected).
                    player.playImmediately(atRate: Float(self.snapshot.rate))
                case .failed:
                    // Fold in the underlying NSError's domain/code and the file's actual size so
                    // a report can tell a missing/empty file from an undecodable one.
                    let nsError = (item.error ?? player.error) as NSError?
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value
                    let detail = "\(nsError?.localizedDescription ?? "unknown error")"
                        + " [\(nsError?.domain ?? "?"):\(nsError?.code ?? 0)]"
                        + ", file size: \(size.map(String.init) ?? "missing")"
                    self.publish(.problem(.other,
                                          message: String(localized: "This chapter could not be played (\(detail))."),
                                          code: "item-\(nsError?.domain ?? "unknown")-\(nsError?.code ?? 0)"),
                                 token: currentToken)
                case .unknown:
                    self.publish(.buffering, token: currentToken)
                @unknown default:
                    self.publish(.problem(.other, message: String(localized: "This chapter could not be played."),
                                          code: "item-unknownStatus"), token: currentToken)
                }
            }
        }
        // Watchdog for the two silent hangs: an item that never becomes ready, and a ready item
        // whose position never advances. Both become a Problem Card with a code.
        Task { [weak self] in
            var lastPosition: TimeInterval = -1
            var lastProgressAt = Date()
            let stallTimeout: TimeInterval = 20
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, currentToken == self.token else { return }
                guard self.didBecomeReadyToken == currentToken else {
                    if Date().timeIntervalSince(lastProgressAt) > stallTimeout {
                        let detail = item.error?.localizedDescription
                            ?? player.error?.localizedDescription
                            ?? "status: \(item.status.rawValue), reachable via file: \(FileManager.default.fileExists(atPath: url.path))"
                        self.publish(.problem(.stalled,
                                              message: String(localized: "This chapter never became playable (\(detail))."),
                                              code: "neverReady-\(item.status.rawValue)"),
                                     token: currentToken)
                        return
                    }
                    continue
                }
                // Paused by the user is not a stall.
                if player.timeControlStatus == .paused {
                    lastProgressAt = Date()
                    continue
                }
                let position = player.currentTime().seconds
                if position.isFinite, position > lastPosition + 0.05 {
                    lastPosition = position
                    lastProgressAt = Date()
                    continue
                }
                guard Date().timeIntervalSince(lastProgressAt) > stallTimeout else { continue }
                let code = WatchStallCode.make(timeControlStatus: player.timeControlStatus.rawValue,
                                               reason: player.reasonForWaitingToPlay?.rawValue)
                self.publish(.problem(.stalled,
                                      message: String(localized: "The audio loaded but never started playing."),
                                      code: code),
                             token: currentToken)
                return
            }
        }
        playerStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, currentToken == self.token else { return }
                if case .failed = self.snapshot.phase { return }
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
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let message = error?.localizedDescription ?? String(localized: "This chapter stopped unexpectedly.")
            let code = "itemStopped-\(error?.domain ?? "unknown")-\(error?.code ?? 0)"
            Task { @MainActor in self?.publish(.problem(.other, message: message, code: code), token: currentToken) }
        }
        playerNotificationObservers.append(contentsOf: [end, failed])
    }

    private func itemEnded(token currentToken: Int) {
        guard currentToken == token else { return }
        persistPosition()
        // §5 C3: "End of Chapter" sleep stops here instead of advancing.
        if sleepTimer?.mode == .endOfChapter {
            publish(.paused, token: currentToken)
            sleepFired()
            return
        }
        guard snapshot.canGoNext, let book else {
            publish(.ended, token: currentToken)
            return
        }
        // §5 S3: at a boundary with no file and no way to stream, stop cleanly and say why —
        // never a silent "Buffering…".
        let next = book.chapters[snapshot.chapterIndex + 1]
        let canStream = streamingAllowed() && next.approvedStreamURL != nil
        let resolvable = (try? WatchPlaybackSourceResolver.resolve(
            bookID: book.id, chapter: next, downloadsRoot: downloadsRoot, allowsStreaming: canStream)) != nil
        if resolvable {
            nextChapter()
        } else {
            publish(.problem(.chapterUnavailable,
                             message: String(localized: "Chapter \(next.index + 1) isn't on this watch, and your iPhone isn't nearby to stream it."),
                             code: "nextChapterUnavailable"),
                    token: currentToken)
        }
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
            pausedAt = Date()
            publish(.interruption, token: token)
            persistPosition()
        } else if let rawOptions,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
            Task { [weak self] in
                guard let self else { return }
                do { try await activateAudioSession(); player?.playImmediately(atRate: Float(snapshot.rate)) }
                catch { publishActivationFailure(error, token: token) }
            }
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        player?.pause()
        pausedAt = Date()
        publish(.routeLost, token: token)
        persistPosition()
    }

    /// AirPods double-press = forward 30 s, triple-press = back 15 s (§5 remote commands); the
    /// chapter-skip commands are disabled so a press never jumps a whole chapter.
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: WatchSkip.forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: WatchSkip.backward)]
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(by: WatchSkip.forward); return .success }
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -WatchSkip.backward); return .success }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2].map { NSNumber(value: $0) }
        add(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.setRate(Double(event.playbackRate))
            return .success
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
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
        snapshot = WatchPlaybackSnapshot(phase: .failed(message), eventToken: token,
                                         failureKind: .other, failureCode: "noPlayableChapter")
        publish()
    }

    /// §5 S2: only a real activation failure becomes "Connect headphones". Anything else from
    /// AVFoundation is a playback failure with its own code (S1), never collapsed into a
    /// headphones message.
    private func publishActivationFailure(_ error: Error, token currentToken: Int) {
        let nsError = error as NSError
        let code = "activation-\(nsError.domain)-\(nsError.code)"
        if nsError.domain == AVFoundationErrorDomain || nsError.domain == NSOSStatusErrorDomain {
            publish(.problem(.noOutput, message: String(localized: "Connect Bluetooth headphones, then try again."),
                             code: code), token: currentToken)
        } else {
            publish(.problem(.other, message: String(localized: "Playback failed: \(error.localizedDescription)"),
                             code: code), token: currentToken)
        }
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
}
