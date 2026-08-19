import Foundation
import AVFoundation
import Observation
import VoxglassCore

/// Plays one paragraph's audio file on the watch. Crown stays volume-only; paragraph
/// movement is by buttons/swipe, so this player is deliberately minimal. Used only
/// from the main actor, so it stays a plain `@Observable` class.
@MainActor
@Observable
public final class WatchSegmentPlayer {

    public private(set) var isPlaying = false
    public private(set) var currentParagraphID: UUID?
    public private(set) var currentTime: TimeInterval = 0
    public var onFinished: ((UUID) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?

    public init() {}

    public func load(url: URL, paragraphID: UUID) {
        player?.pause()
        removeObserver()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentParagraphID = paragraphID
        currentTime = 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = time.seconds
            }
        }
    }

    public func play() {
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func stop() {
        player?.pause()
        player = nil
        isPlaying = false
        removeObserver()
    }

    private func removeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}
