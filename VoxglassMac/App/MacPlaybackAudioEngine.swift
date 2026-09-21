import AVFoundation
import Foundation
import VoxglassCore

@MainActor
final class MacPlaybackAudioEngine: NSObject, AudioEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private(set) var lastEndPosition: TimeInterval = 0
    private(set) var lastEndDuration: TimeInterval?
    private(set) var rate: Float = 1

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onItemChanged: (@MainActor () -> Void)?
    var onSilenceChanged: (@MainActor (Bool) -> Void)?

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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastEndPosition = self.currentTime
                self.lastEndDuration = self.duration
                self.onPlaybackEnded?()
            }
        }
        await seek(to: startTime)
        onItemChanged?()
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
