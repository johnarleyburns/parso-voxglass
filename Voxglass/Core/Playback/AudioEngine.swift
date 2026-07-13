import Foundation

/// The playback engine seam. Widened (Step 0 of the competitive gap plan) so
/// `PlaybackCoordinator` never has to downcast to the concrete
/// `AVPlayerAudioEngine`: every effect it needs — preload, cancel-preload,
/// prefetch, rate, volume, EQ, item-changed — is expressed here. This is what
/// makes speed, sleep timer, bookmarks, artwork, and skip intervals unit-testable
/// against a `FakeAudioEngine` with no AVFoundation and no simulator.
@MainActor
protocol AudioEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var isPlaying: Bool { get }
    var rate: Float { get }                    // P0-1
    var volume: Float { get set }              // P0-2 fade-out
    var isEQEngaged: Bool { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    var onItemChanged: (@MainActor () -> Void)? { get set }
    var onSilenceChanged: (@MainActor (Bool) -> Void)? { get set }

    func configureAudioSession()
    func load(url: URL, startTime: TimeInterval) async throws
    func play()
    func pause()
    func seek(to position: TimeInterval) async
    func setRate(_ rate: Float)                // P0-1
    func preloadNext(url: URL)
    func cancelPreload()                        // sleep timer depends on this
    func prefetchIntoCache(urls: [URL])
    func setEQEngaged(_ engaged: Bool)
    func applyEQPreset(_ preset: EQPreset)
    func setEQGain(_ gain: Float, at band: Int)
    func setEQGains(_ gains: [Float])
}

enum AudioEngineError: Error, LocalizedError {
    case missingPlayableURL

    var errorDescription: String? {
        switch self {
        case .missingPlayableURL:
            "This chapter does not have a playable audio URL."
        }
    }
}
