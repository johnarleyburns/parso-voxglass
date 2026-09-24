import Foundation

/// The playback engine seam. Widened (Step 0 of the competitive gap plan) so
/// `PlaybackCoordinator` never has to downcast to the concrete
/// `AVPlayerAudioEngine`: every effect it needs — preload, cancel-preload,
/// prefetch, rate, volume, EQ, item-changed — is expressed here. This is what
/// makes speed, sleep timer, bookmarks, artwork, and skip intervals unit-testable
/// against a `FakeAudioEngine` with no AVFoundation and no simulator.
@MainActor
public protocol AudioEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var isPlaying: Bool { get }
    /// True once an item is loaded and the engine reports a finite playback time.
    /// The anti-zero guard uses this to refuse persisting a bogus `0` in the
    /// window after `load()` and before the item is ready.
    var isReady: Bool { get }
    var rate: Float { get }                    // P0-1
    var volume: Float { get set }              // P0-2 fade-out
    var isEQEngaged: Bool { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }
    /// Reports a stall or unverified/failed playback event. Issues preserve the
    /// current chapter; only `onPlaybackEnded` may advance the queue.
    var onPlaybackIssue: (@MainActor (AudioEngineIssue) -> Void)? { get set }
    var onItemChanged: (@MainActor () -> Void)? { get set }
    var onSilenceChanged: (@MainActor (Bool) -> Void)? { get set }

    /// Whether a next chapter is currently queued behind the active item.
    /// PlaybackCoordinator uses this to wait for AVQueuePlayer's item-change
    /// callback instead of racing it with a second manual load.
    var hasPreloadedItem: Bool { get }
    /// True after the queued item has become the engine's current item. This
    /// remains explicit because AVFoundation can deliver the end notification
    /// before or after the KVO current-item notification.
    var isCurrentItemPreloaded: Bool { get }

    /// Playback position and reported duration of the item that most recently
    /// reached (or prematurely reported) its end, captured from the item itself
    /// at the moment of the end event. `nil` duration means the end could not be
    /// verified (e.g. a streaming item with an unknown duration). The coordinator
    /// uses these to reject a *spurious* item change — AVFoundation can emit
    /// `AVPlayerItemDidPlayToEndTime` early on some device/file combinations,
    /// which would otherwise skip the chapter the user was listening to.
    var lastEndPosition: TimeInterval { get }
    var lastEndDuration: TimeInterval? { get }
    /// True only when the most recent end event was verified against a finite
    /// duration. Queue item changes without this proof must not advance.
    var lastEndWasVerified: Bool { get }

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

/// A playback-engine problem that must not be interpreted as chapter
/// completion. The app layer translates AVFoundation events into this small
/// platform-neutral vocabulary so the coordinator can preserve the savepoint
/// and expose a retry path without importing AVFoundation.
public enum AudioEngineIssue: Equatable, Sendable {
    case stalled
    case failed(String)
    case unverifiedEnd

    public var userMessage: String {
        switch self {
        case .stalled:
            return "Playback paused while the audio source was buffering."
        case .failed(let message):
            return message.isEmpty ? "The audio could not continue playing." : message
        case .unverifiedEnd:
            return "Playback stopped before the chapter end could be verified."
        }
    }
}

public enum AudioEngineError: Error, LocalizedError {
    case missingPlayableURL
    case unplayableAudio

    public var errorDescription: String? {
        switch self {
        case .missingPlayableURL:
            "This chapter does not have a playable audio URL."
        case .unplayableAudio:
            "This chapter's downloaded audio could not be opened."
        }
    }
}
