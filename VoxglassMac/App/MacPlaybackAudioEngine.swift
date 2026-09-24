import AVFoundation
import Foundation
import VoxglassCore

@MainActor
final class MacPlaybackAudioEngine: NSObject, AudioEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private let issueObserverRegistry = IssueObserverRegistry()
    private var reportedIssueKinds = Set<String>()
    private(set) var lastEndPosition: TimeInterval = 0
    private(set) var lastEndDuration: TimeInterval?
    private(set) var lastEndWasVerified = false
    private(set) var rate: Float = 1

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onPlaybackIssue: (@MainActor (AudioEngineIssue) -> Void)?
    var onItemChanged: (@MainActor () -> Void)?
    var onSilenceChanged: (@MainActor (Bool) -> Void)?
    var hasPreloadedItem: Bool { false }
    var isCurrentItemPreloaded: Bool { false }

    var currentTime: TimeInterval { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: TimeInterval? {
        let value = player.currentItem?.duration.seconds ?? .nan
        return value.isFinite ? value : nil
    }
    var isReady: Bool { player.currentItem != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var isEQEngaged: Bool { false }

    func configureAudioSession() {}

    func load(url: URL, startTime: TimeInterval) async throws {
        tearDownObservers()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        lastEndPosition = 0
        lastEndDuration = nil
        lastEndWasVerified = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastEndPosition = self.currentTime
                self.lastEndDuration = self.duration
                guard let duration = self.duration,
                      self.currentTime >= duration - 0.75 else {
                    self.lastEndWasVerified = false
                    self.reportIssue(.unverifiedEnd)
                    return
                }
                self.lastEndWasVerified = true
                self.onPlaybackEnded?()
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.reportIssue(.failed(item.error?.localizedDescription ?? "The audio could not be opened."))
            }
        }
        let center = NotificationCenter.default
        issueObserverRegistry.tokens.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.reportIssue(.failed(error?.localizedDescription ?? "The audio stopped unexpectedly."))
            }
        })
        issueObserverRegistry.tokens.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportIssue(.stalled) }
        })
        await seek(to: startTime)
        onItemChanged?()
    }

    private func reportIssue(_ issue: AudioEngineIssue) {
        let key: String
        switch issue {
        case .stalled: key = "stalled"
        case .failed: key = "failed"
        case .unverifiedEnd: key = "unverifiedEnd"
        }
        guard reportedIssueKinds.insert(key).inserted else { return }
        player.pause()
        onPlaybackIssue?(issue)
    }

    private func tearDownObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        for token in issueObserverRegistry.tokens {
            NotificationCenter.default.removeObserver(token)
        }
        issueObserverRegistry.tokens.removeAll()
        reportedIssueKinds.removeAll()
    }

    func play() { player.playImmediately(atRate: rate) }
    func pause() { player.pause() }
    func seek(to position: TimeInterval) async {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: max(0, position), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in continuation.resume() }
        }
    }
    func setRate(_ rate: Float) {
        self.rate = rate
        if isPlaying { player.rate = rate }
    }
    func preloadNext(url: URL) {}
    func cancelPreload() {}
    func prefetchIntoCache(urls: [URL]) {}
    func setEQEngaged(_ engaged: Bool) {}
    func applyEQPreset(_ preset: EQPreset) {}
    func setEQGain(_ gain: Float, at band: Int) {}
    func setEQGains(_ gains: [Float]) {}

    private final class IssueObserverRegistry: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }
}

@MainActor
final class MacPlaybackBridge: PlaybackPlatformBridge {
    var onRemoteCommand: ((PlaybackRemoteCommand) -> Void)?

    func updateNowPlaying(_ info: NowPlayingInfo?) {}
    func setArtwork(_ imageData: Data?) {}
    func setSkipIntervals(backward: Int, forward: Int) {}
    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await work() }
    }
}
