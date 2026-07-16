import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import VoxglassCore

/// The concrete platform implementation of `PlaybackPlatformBridge`. Owns every
/// MediaPlayer / UIKit / AVAudioSession touch-point that `PlaybackCoordinator`
/// used to hold inline: the lock-screen Now Playing dictionary, artwork
/// rendering, the remote command center, app-lifecycle position saves, and audio
/// interruption / route-change forwarding. Keeping this in the app layer lets the
/// coordinator's playback logic stay platform-free and host-testable.
@MainActor
final class SystemPlaybackBridge: NSObject, PlaybackPlatformBridge {
    var onRemoteCommand: ((PlaybackRemoteCommand) -> Void)?

    /// Weakly held so the bridge can forward app-lifecycle and audio-interruption
    /// notifications back into playback. Set by `AppServices` after construction.
    weak var coordinator: PlaybackCoordinator?

    private var latestInfo: NowPlayingInfo?
    private var currentArtwork: MPMediaItemArtwork?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        currentArtwork = Self.fallbackArtwork
        configureRemoteCommands()
        configureNotifications()
    }

    // MARK: - PlaybackPlatformBridge

    func updateNowPlaying(_ info: NowPlayingInfo?) {
        latestInfo = info
        guard let info else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = mpInfo(from: info)
    }

    func setArtwork(_ imageData: Data?) {
        if let imageData, let image = UIImage(data: imageData) {
            currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            currentArtwork = Self.fallbackArtwork
        }
        // Re-emit so the lock screen picks up the new artwork without waiting for
        // the next Now Playing refresh.
        if let info = latestInfo {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = mpInfo(from: info)
        }
    }

    func setSkipIntervals(backward: Int, forward: Int) {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
    }

    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void) {
        let taskID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task { @MainActor in
            await work()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
    }

    // MARK: - Now Playing dictionary

    private func mpInfo(from info: NowPlayingInfo) -> [String: Any] {
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyAlbumTitle: info.albumTitle,
            MPMediaItemPropertyArtist: info.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.reportedRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: info.defaultRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let duration = info.duration {
            dict[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = currentArtwork {
            dict[MPMediaItemPropertyArtwork] = artwork
        }
        return dict
    }

    /// A static, procedurally-rendered cover used for books without art. Built
    /// once, never per tick.
    private static let fallbackArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 512, height: 512)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.16, green: 0.11, blue: 0.03, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 220, weight: .regular)
            if let symbol = UIImage(systemName: "headphones", withConfiguration: symbolConfig)?
                .withTintColor(UIColor(red: 0.93, green: 0.70, blue: 0.36, alpha: 1), renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2,
                                     y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()

    // MARK: - Remote command center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.play); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.pause); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.togglePlayPause); return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.skipForward); return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.skipBackward); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.nextChapter); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?(.previousChapter); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onRemoteCommand?(.seek(to: event.positionTime)); return .success
        }
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackRate.systemLadder.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            self?.onRemoteCommand?(.setRate(event.playbackRate)); return .success
        }
    }

    // MARK: - App lifecycle + audio interruptions

    private func configureNotifications() {
        let center = NotificationCenter.default
        // willResignActive is the last moment a synchronous main-thread write is
        // guaranteed to run before background/kill. No Task hop on purpose.
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.handleWillResignActive() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.handleWillBackgroundOrTerminate() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.handleWillBackgroundOrTerminate() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.coordinator?.handleAudioInterruptionBegan()
                case .ended: self?.coordinator?.handleAudioInterruptionEnded()
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.handleAudioRouteChanged() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
