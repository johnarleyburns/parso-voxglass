import AVFoundation
import Foundation

@MainActor
final class AVPlayerAudioEngine: NSObject, AudioEngine {
    private let player = AVQueuePlayer()
    private var endObserver: NSObjectProtocol?
    private var currentItemObserver: NSKeyValueObservation?
    private var preloadedItem: AVPlayerItem?
    private let eqProcessor = EQAudioProcessor()

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onItemChanged: (@MainActor () -> Void)?

    var isEQEngaged: Bool { eqProcessor.isEngaged }

    func engageEQ() {
        if let item = player.currentItem {
            eqProcessor.attach(to: item)
        }
    }

    func disengageEQ() {
        if let item = player.currentItem {
            eqProcessor.detach(from: item)
        }
    }

    func setEQGain(_ gain: Float, at band: Int) {
        eqProcessor.setGain(gain, at: band)
    }

    func applyEQPreset(_ preset: EQPreset) {
        eqProcessor.applyPreset(preset)
    }

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
        tearDownCurrentItem()
        preloadedItem = nil

        let item = AVPlayerItem(url: url)
        player.removeAllItems()
        player.insert(item, after: nil)
        observe(item: item, isPreloaded: false)

        if eqProcessor.isEngaged {
            eqProcessor.attach(to: item)
        }

        await seek(to: startTime)
    }

    func preloadNext(url: URL) {
        guard preloadedItem == nil else { return }

        let item = AVPlayerItem(url: url)
        preloadedItem = item

        if player.canInsert(item, after: player.currentItem) {
            player.insert(item, after: player.currentItem)
            observe(item: item, isPreloaded: true)

            if eqProcessor.isEngaged {
                eqProcessor.attach(to: item)
            }
        }
    }

    private func tearDownCurrentItem() {
        if let currentItem = player.currentItem {
            eqProcessor.detach(from: currentItem)
        }
        removeObservers()
    }

    func cancelPreload() {
        if let item = preloadedItem {
            eqProcessor.detach(from: item)
            player.remove(item)
            preloadedItem = nil
        }
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

    private func observe(item: AVPlayerItem, isPreloaded: Bool) {
        let center = NotificationCenter.default

        endObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let endedItem = notification.object as? AVPlayerItem,
                   endedItem == self.preloadedItem {
                    self.preloadedItem = nil
                }
                self.onPlaybackEnded?()
            }
        }

        if isPreloaded {
            currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if player.currentItem == item {
                        self.preloadedItem = nil
                        self.onItemChanged?()
                    }
                }
            }
        }
    }

    private func removeObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        currentItemObserver?.invalidate()
        currentItemObserver = nil
    }

    deinit {
        // Inline cleanup: deinit is nonisolated but these operations are safe
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        currentItemObserver?.invalidate()
    }
}
