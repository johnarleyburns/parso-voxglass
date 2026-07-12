import AVFoundation
import Foundation

@MainActor
final class AVPlayerAudioEngine: NSObject, AudioEngine {
    private let player = AVQueuePlayer()
    private var endObserver: NSObjectProtocol?
    private var currentItemObserver: NSKeyValueObservation?
    private var preloadedItem: AVPlayerItem?
    private let eqProcessor = EQAudioProcessor()
    private let loaderQueue = DispatchQueue(label: "guru.parso.voxglass.loaders")
    private var loaders: [CachingResourceLoader] = []
    private var prefetchLoaders: [CachingResourceLoader] = []
    private var prefetchItems: [AVPlayerItem] = []
    private var eqEngagedDesired = false

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onItemChanged: (@MainActor () -> Void)?

    /// Builds an AVPlayerItem that routes remote URLs through the streaming cache.
    private func makePlayerItem(for url: URL) -> AVPlayerItem {
        guard CachingResourceLoader.isRemoteCacheable(url) else {
            return AVPlayerItem(url: url)
        }
        let cacheURL = CachingResourceLoader.cacheURL(for: url)
        let loader = CachingResourceLoader(originalURL: url)
        loaders.append(loader)
        let asset = AVURLAsset(url: cacheURL)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
        return AVPlayerItem(asset: asset)
    }

    /// Warms the streaming cache for one upcoming chapter without affecting playback.
    func prefetchIntoCache(url: URL) {
        prefetchIntoCache(urls: [url])
    }

    /// Warms the streaming cache for up to `urls.count` upcoming chapters. The
    /// depth is decided by `PlaybackCoordinator.resolvedPrefetchDepth` (free tier
    /// stays at 1, which powers near-gapless); here we just honor the list.
    func prefetchIntoCache(urls: [URL]) {
        let cacheable = urls.filter { CachingResourceLoader.isRemoteCacheable($0) }
        guard !cacheable.isEmpty else { return }
        let cap = max(cacheable.count, 1)
        for url in cacheable {
            guard prefetchItems.count < cap else { break }
            let cacheURL = CachingResourceLoader.cacheURL(for: url)
            let loader = CachingResourceLoader(originalURL: url)
            prefetchLoaders.append(loader)
            let asset = AVURLAsset(url: cacheURL)
            asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
            let item = AVPlayerItem(asset: asset)
            prefetchItems.append(item)
            // Referencing the item's asset keys triggers the resource loader to begin
            // filling the cache in the background.
            asset.loadValuesAsynchronously(forKeys: ["playable"]) { }
        }
    }

    var isEQEngaged: Bool { eqEngagedDesired }

    /// Sets the desired engaged state and attaches/detaches the tap on the current
    /// item immediately. The desired flag also drives re-attachment in `load` and
    /// `preloadNext` so EQ survives track changes and relaunch.
    func setEQEngaged(_ engaged: Bool) {
        eqEngagedDesired = engaged
        guard let item = player.currentItem else { return }
        if engaged {
            eqProcessor.attach(to: item)
        } else {
            eqProcessor.detach(from: item)
        }
    }

    func engageEQ() {
        setEQEngaged(true)
    }

    func disengageEQ() {
        setEQEngaged(false)
    }

    func setEQGain(_ gain: Float, at band: Int) {
        eqProcessor.setGain(gain, at: band)
    }

    func setEQGains(_ gains: [Float]) {
        for (band, gain) in gains.enumerated() {
            eqProcessor.setGain(gain, at: band)
        }
    }

    func applyEQPreset(_ preset: EQPreset) {
        eqProcessor.applyPreset(preset)
    }

    var eqGains: [Float] { eqProcessor.currentGains }

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
        shutdownPrefetch()

        let item = makePlayerItem(for: url)
        player.removeAllItems()
        player.insert(item, after: nil)
        observe(item: item, isPreloaded: false)

        if eqEngagedDesired {
            eqProcessor.attach(to: item)
        }

        await seek(to: startTime)
    }

    func preloadNext(url: URL) {
        guard preloadedItem == nil else { return }

        let item = makePlayerItem(for: url)
        preloadedItem = item

        if player.canInsert(item, after: player.currentItem) {
            player.insert(item, after: player.currentItem)
            observe(item: item, isPreloaded: true)

            if eqEngagedDesired {
                eqProcessor.attach(to: item)
            }
        }
    }

    private func shutdownPrefetch() {
        prefetchLoaders.forEach { $0.shutdown() }
        prefetchLoaders.removeAll()
        prefetchItems.removeAll()
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
