import AVFoundation
import Foundation
import VoxglassCore

@MainActor
final class AVPlayerAudioEngine: NSObject, AudioEngine {
    private let player = AVQueuePlayer()
    /// End-of-playback observers keyed by item identity. Kept per item so a
    /// `preloadNext` (or a second `load`) never replaces — and thereby leaks —
    /// the current item's observer: with the old single-slot `endObserver` every
    /// gapless advance leaked the previous item's observer, and a stale observer
    /// could keep firing for an item that was never at its end.
    private var endObservers: [ObjectIdentifier: ObserverToken] = [:]
    private var currentItemObserver: NSKeyValueObservation?
    private var preloadedItem: AVPlayerItem?

    /// Playback position and reported duration of the item whose end event was
    /// most recently seen, read from the item itself before the queue advances.
    /// Used by the coordinator to reject a spurious item change (§consumer).
    private(set) var lastEndPosition: TimeInterval = 0
    private(set) var lastEndDuration: TimeInterval?
    private let eqProcessor = EQAudioProcessor()
    private let loaderQueue = DispatchQueue(label: "guru.parso.voxglass.loaders")
    private var loaders: [CachingResourceLoader] = []
    private var prefetchLoaders: [CachingResourceLoader] = []
    private var prefetchItems: [AVPlayerItem] = []
    private var eqEngagedDesired = false

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onItemChanged: (@MainActor () -> Void)?
    var onSilenceChanged: (@MainActor (Bool) -> Void)? {
        get { eqProcessor.onSilenceChanged }
        set { eqProcessor.onSilenceChanged = newValue }
    }

    /// The desired playback rate. Applied via `player.defaultRate` so every
    /// resume path (remote play, interruption resume, chapter change) inherits it
    /// for free. Default 1.0.
    private(set) var rate: Float = 1.0

    /// Builds an AVPlayerItem that routes remote URLs through the streaming cache.
    /// `audioTimePitchAlgorithm` is set to `.spectral` on every item so variable
    /// speed (0.5–3.5x) keeps pitch correct and the gapless preloaded item carries
    /// the same algorithm across the auto-advance.
    private func makePlayerItem(for url: URL) -> AVPlayerItem {
        let options: [String: Any] = StreamCacheUtils.audioMIMEType(for: url).map {
            [AVURLAssetOverrideMIMETypeKey: $0]
        } ?? [:]
        let item: AVPlayerItem
        if CachingResourceLoader.isRemoteCacheable(url) {
            let cacheURL = CachingResourceLoader.cacheURL(for: url)
            let loader = CachingResourceLoader(originalURL: url)
            loaders.append(loader)
            let asset = AVURLAsset(url: cacheURL, options: options)
            asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
            item = AVPlayerItem(asset: asset)
        } else {
            let asset = AVURLAsset(url: url, options: options)
            item = AVPlayerItem(asset: asset)
        }
        item.audioTimePitchAlgorithm = .spectral
        return item
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
            item.audioTimePitchAlgorithm = .spectral
            prefetchItems.append(item)
            // Referencing the item's asset keys triggers the resource loader to begin
            // filling the cache in the background.
            Task { _ = try? await asset.load(.isPlayable) }
        }
    }

    var isEQEngaged: Bool { eqEngagedDesired }

    /// Sets the desired engaged state and toggles EQ stages on all live taps
    /// (free users get the tap for normalization + silence detection but with
    /// stages bypassed). The tap stays attached unconditionally.
    func setEQEngaged(_ engaged: Bool) {
        eqEngagedDesired = engaged
        eqProcessor.setEQStagesEnabled(engaged)
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

    var isReady: Bool {
        player.currentItem != nil && player.currentTime().seconds.isFinite
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

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Sets the playback rate via `player.defaultRate` (iOS 16+) so every future
    /// `play()` resumes at this rate. Only nudges the live `player.rate` when
    /// already playing — assigning `rate` to a paused player would start playback.
    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if player.timeControlStatus == .playing {
            player.rate = rate
        }
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

        let isPlayable = try await item.asset.load(.isPlayable)
        guard isPlayable else { throw AudioEngineError.unplayableAudio }

        eqProcessor.attach(to: item)
        eqProcessor.setEQStagesEnabled(eqEngagedDesired)

        await seek(to: startTime)
    }

    func preloadNext(url: URL) {
        guard preloadedItem == nil else { return }

        let item = makePlayerItem(for: url)
        preloadedItem = item

        if player.canInsert(item, after: player.currentItem) {
            player.insert(item, after: player.currentItem)
            observe(item: item, isPreloaded: true)

            eqProcessor.attach(to: item)
            eqProcessor.setEQStagesEnabled(eqEngagedDesired)
        }
    }

    private func shutdownPrefetch() {
        prefetchLoaders.forEach { $0.shutdown() }
        prefetchLoaders.removeAll()
        prefetchItems.removeAll()
    }

    private func tearDownCurrentItem() {
        eqProcessor.detachAll()
        removeObservers()
        loaders.forEach { $0.shutdown() }
        loaders.removeAll()
    }

    func cancelPreload() {
        if let item = preloadedItem {
            eqProcessor.detach(from: item)
            removeEndObserver(for: item)
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
        let key = ObjectIdentifier(item)
        // A given item is observed once; replace any stale token for it rather
        // than stacking observers that would each fire onPlaybackEnded.
        if let existing = endObservers[key] {
            center.removeObserver(existing.value)
        }
        let token = ObserverToken(value: center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main,
            using: { [weak self] notification in
                let notification = UncheckedSendable(value: notification)
                Task { @MainActor [weak self] in
                    guard let self,
                          let endedItem = notification.value.object as? AVPlayerItem else { return }
                    self.handleItemDidPlayToEnd(endedItem)
                }
            }
        ))
        endObservers[key] = token

        if isPreloaded {
            currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if player.currentItem == item {
                        self.preloadedItem = nil
                        // The previous chapter's item has left the queue; drop its
                        // now-orphaned EQ tap so only live items keep taps.
                        self.eqProcessor.pruneTaps(keeping: player.items())
                        self.onItemChanged?()
                    }
                }
            }
        }
    }

    /// Handles an end-of-playback event. AVFoundation can report
    /// `AVPlayerItemDidPlayToEndTime` prematurely on some device/file
    /// combinations (a 20-minute chapter "ending" at 5:00); advancing then
    /// loses the user's place. Only a *genuine* end — the item's playback
    /// position is at its reported duration — advances playback. A spurious end
    /// resumes the player if it stopped and never notifies the coordinator.
    private func handleItemDidPlayToEnd(_ item: AVPlayerItem) {
        if item == preloadedItem {
            preloadedItem = nil
        }
        let position = item.currentTime().seconds
        let duration = item.duration.seconds
        let durationIsUsable = duration.isFinite && duration > 0
        if durationIsUsable && position.isFinite {
            lastEndPosition = position
            lastEndDuration = duration
        } else {
            // Unknown duration (e.g. streaming): cannot verify, and a stale
            // value must not make the coordinator reject a genuine advance.
            lastEndPosition = 0
            lastEndDuration = nil
        }

        let isGenuineEnd = !durationIsUsable || !position.isFinite || position >= duration - 0.75
        if isGenuineEnd {
            // Real end: the item will not end again, so drop its observer and
            // let the coordinator advance.
            removeEndObserver(for: item)
            onPlaybackEnded?()
        } else {
            // Spurious end: resume if the player stopped, never advance.
            if player.timeControlStatus == .paused, player.currentItem != nil {
                player.play()
            }
        }
    }

    private func removeEndObserver(for item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        guard let token = endObservers.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(token.value)
    }

    private func removeObservers() {
        for token in endObservers.values {
            NotificationCenter.default.removeObserver(token.value)
        }
        endObservers.removeAll()
        currentItemObserver?.invalidate()
        currentItemObserver = nil
    }

    deinit {
        // Inline cleanup: deinit is nonisolated but these operations are safe
        for token in endObservers.values {
            NotificationCenter.default.removeObserver(token.value)
        }
        currentItemObserver?.invalidate()
    }

    private final class ObserverToken: @unchecked Sendable {
        let value: NSObjectProtocol
        init(value: NSObjectProtocol) { self.value = value }
    }

    private struct UncheckedSendable<Value>: @unchecked Sendable {
        let value: Value
    }
}
