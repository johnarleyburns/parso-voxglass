import AVFoundation
import Foundation
import VoxglassCore

private final class LoadResolutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return false }
        resolved = true
        return true
    }
}

/// Thin watchOS adapter around `AVPlayer`. Implements the `AudioEngine` protocol
/// so `PlaybackCoordinator` can drive playback with zero platform-specific logic.
@MainActor
public final class WatchPlaybackEngine: AudioEngine {

    // MARK: - AudioEngine conformance

    public var onPlaybackEnded: (@MainActor () -> Void)?
    public var onItemChanged: (@MainActor () -> Void)?
    public var onSilenceChanged: (@MainActor (Bool) -> Void)?

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public var isPlaying: Bool { player?.timeControlStatus == .playing }
    public var isReady: Bool { player?.currentItem?.status == .readyToPlay }
    public var rate: Float { player?.rate ?? 1.0 }
    public var volume: Float {
        get { player?.volume ?? 1.0 }
        set { player?.volume = newValue }
    }
    public var isEQEngaged: Bool { false }
    public private(set) var lastEndPosition: TimeInterval = 0
    public private(set) var lastEndDuration: TimeInterval?

    private var player: AVPlayer?
    private var currentItemURL: URL?
    private var timeObserverToken: ObserverToken?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var boundaryObserver: ObserverToken?
    private let audioSession = AVAudioSession.sharedInstance()

    public init() {}

    public func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try audioSession.setActive(true)
        } catch {
            // Route failure handled by Now Playing UI
        }
    }

    public func load(url: URL, startTime: TimeInterval) async throws {
        // For watchOS, use AVAudioPlayerNode with AVAudioFile for streaming.
        // AVPlayer works on watchOS but the streaming/resource-loader patterns
        // differ. Keep it simple: direct AVPlayer usage.
        stopCurrentItem()

        let options: [String: Any] = StreamCacheUtils.audioMIMEType(for: url).map {
            [AVURLAssetOverrideMIMETypeKey: $0]
        } ?? [:]
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        currentItemURL = url

        // Observe status
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resolution = LoadResolutionState()
            statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .readyToPlay || item.status == .failed else { return }
                guard resolution.claim() else { return }
                continuation.resume()
            }
            // Timeout after 30s
            Task {
                try? await Task.sleep(for: .seconds(30))
                if resolution.claim() {
                    continuation.resume()
                }
            }
        }

        guard playerItem.status == .readyToPlay else {
            throw WatchPlaybackError.loadFailed
        }

        duration = playerItem.duration.seconds
        if duration?.isNaN == true || duration?.isInfinite == true {
            duration = nil
        }

        // Seek if needed
        if startTime > 0 {
            await player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = ObserverToken(value: player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.currentTime = time.seconds
            }
        })

        // End-of-item notification
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self, weak playerItem] _ in
            Task { @MainActor in
                guard let self else { return }
                // Capture the ended item's position/duration so the coordinator
                // can reject a spurious end (a premature AVPlayerItemDidPlayToEndTime
                // must not advance the review queue).
                if let item = playerItem {
                    let pos = item.currentTime().seconds
                    let dur = item.duration.seconds
                    self.lastEndPosition = pos.isFinite ? pos : 0
                    self.lastEndDuration = (dur.isFinite && dur > 0) ? dur : nil
                } else {
                    self.lastEndPosition = 0
                    self.lastEndDuration = nil
                }
                self.onPlaybackEnded?()
            }
        }
    }

    public func play() {
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    public func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        await player?.seek(to: time)
        currentTime = position
    }

    public func setRate(_ rate: Float) {
        player?.rate = rate
    }

    public func preloadNext(url: URL) {
        // watchOS: preloading is constrained; this is a no-op for v1
    }

    public func cancelPreload() {
        // No-op for v1
    }

    public func prefetchIntoCache(urls: [URL]) {
        // No-op for v1
    }

    public func setEQEngaged(_ engaged: Bool) {
        // EQ not supported on watchOS
    }

    public func applyEQPreset(_ preset: EQPreset) {
        // EQ not supported on watchOS
    }

    public func setEQGain(_ gain: Float, at band: Int) {
        // EQ not supported on watchOS
    }

    public func setEQGains(_ gains: [Float]) {
        // EQ not supported on watchOS
    }

    // MARK: - Cleanup

    private func stopCurrentItem() {
        if let observer = timeObserverToken {
            player?.removeTimeObserver(observer.value)
            timeObserverToken = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        if let observer = boundaryObserver {
            player?.removeTimeObserver(observer.value)
            boundaryObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentItemURL = nil
        currentTime = 0
        duration = nil
    }

    deinit {
        if let observer = timeObserverToken {
            player?.removeTimeObserver(observer.value)
        }
        statusObserver?.invalidate()
        rateObserver?.invalidate()
        if let observer = boundaryObserver {
            player?.removeTimeObserver(observer.value)
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    private final class ObserverToken: @unchecked Sendable {
        let value: Any

        init(value: Any) {
            self.value = value
        }
    }
}

public enum WatchPlaybackError: Error, LocalizedError {
    case loadFailed

    public var errorDescription: String? {
        switch self {
        case .loadFailed:
            "Could not load this chapter for playback."
        }
    }
}
