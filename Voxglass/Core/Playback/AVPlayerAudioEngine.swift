import AVFoundation
import Foundation

@MainActor
final class AVPlayerAudioEngine: NSObject, AudioEngine {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    var onPlaybackEnded: (@MainActor () -> Void)?

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: TimeInterval? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite else {
            return nil
        }
        return seconds
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            #if compiler(>=6.3)
            let bluetoothHandsFreeOption: AVAudioSession.CategoryOptions = .allowBluetoothHFP
            #else
            let bluetoothHandsFreeOption: AVAudioSession.CategoryOptions = .allowBluetooth
            #endif
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowAirPlay, bluetoothHandsFreeOption, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            assertionFailure("Audio session configuration failed: \(error)")
        }
    }

    func load(url: URL, startTime: TimeInterval) async throws {
        configureAudioSession()
        removeEndObserver()

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPlaybackEnded?()
            }
        }

        await seek(to: startTime)
    }

    func play() {
        configureAudioSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to position: TimeInterval) async {
        let target = CMTime(seconds: max(0, position), preferredTimescale: 600)
        await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}
