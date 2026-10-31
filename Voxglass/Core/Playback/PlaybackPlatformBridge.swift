import Foundation

/// A plain, platform-agnostic description of the "now playing" state. Core builds
/// this from the current session; the app's `PlaybackPlatformBridge` renders it
/// into `MPNowPlayingInfoCenter`. Kept free of MediaPlayer/UIKit so the playback
/// logic compiles and unit-tests on the host (`swift test`).
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var albumTitle: String
    public var artist: String
    public var elapsed: TimeInterval
    public var duration: TimeInterval?
    /// The rate reported to the system (0 when paused so the scrubber stops).
    public var reportedRate: Double
    /// The book's default/target rate.
    public var defaultRate: Double

    public init(
        title: String,
        albumTitle: String,
        artist: String,
        elapsed: TimeInterval,
        duration: TimeInterval?,
        reportedRate: Double,
        defaultRate: Double
    ) {
        self.title = title
        self.albumTitle = albumTitle
        self.artist = artist
        self.elapsed = elapsed
        self.duration = duration
        self.reportedRate = reportedRate
        self.defaultRate = defaultRate
    }
}

/// Remote-control / lock-screen commands the system can send back to playback.
/// The app's bridge subscribes to `MPRemoteCommandCenter` and forwards them here;
/// Core implements the behavior.
public enum PlaybackRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipForward
    case skipBackward
    case nextChapter
    case previousChapter
    case seek(to: TimeInterval)
    case setRate(Float)
}

/// The platform boundary for playback. Core talks only to this protocol; the app
/// provides the concrete `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` /
/// `UIApplication` implementation. `NoopPlaybackBridge` lets the logic run
/// headlessly under `swift test`.
@MainActor
public protocol PlaybackPlatformBridge: AnyObject {
    /// Routes a remote command back into playback. Set by the coordinator.
    var onRemoteCommand: ((PlaybackRemoteCommand) -> Void)? { get set }

    /// Publishes (or clears, when nil) the current now-playing state.
    func updateNowPlaying(_ info: NowPlayingInfo?)

    /// Atomically submits the lock-screen state: the Live Activity decides first,
    /// then Now Playing is cleared or published accordingly.
    func updateLockScreen(nowPlaying: NowPlayingInfo?, liveActivity: LiveActivityContent?)

    /// Publishes review metadata (e.g. CarPlay paragraph review) through the same
    /// Live Activity gate as `updateNowPlaying`. Retained as latest state, and
    /// never written to the system card while a Live Activity owns the lock screen.
    func updateAuxiliaryNowPlaying(title: String, artist: String)

    /// Clears any auxiliary metadata so it cannot leak into later playback.
    func clearAuxiliaryNowPlaying()

    /// Sets the lock-screen artwork from raw image bytes. `nil` selects the
    /// app's bundled fallback artwork.
    func setArtwork(_ imageData: Data?)

    /// Publishes the platform-free Live Activity payload, or clears it.
    func updateLiveActivity(_ content: LiveActivityContent?)

    /// Updates the preferred skip intervals surfaced on the remote command center.
    func setSkipIntervals(backward: Int, forward: Int)

    /// Wraps an async position flush in a background-task assertion so an OS kill
    /// can't drop the enqueued write. The default just runs the work.
    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void)
}

/// Review metadata shown on the Now Playing card outside normal playback.
public struct AuxiliaryNowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

/// Retains the latest auxiliary metadata and decides, using the same Live
/// Activity reconciliation as normal Now Playing, whether it may be published.
public struct AuxiliaryNowPlayingGate: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        /// A Live Activity owns the lock screen: clear the card, publish nothing.
        case clear
        /// Nothing suppresses the metadata; it may be published.
        case publish(AuxiliaryNowPlaying?)
    }

    public private(set) var latest: AuxiliaryNowPlaying?

    public init() {}

    public mutating func update(_ metadata: AuxiliaryNowPlaying?, reconciliation: LiveActivityReconciliation) -> Effect {
        latest = metadata
        switch reconciliation.nowPlayingAction {
        case .clear: return .clear
        case .publishLatest: return .publish(latest)
        }
    }
}

public extension PlaybackPlatformBridge {
    func updateLiveActivity(_ content: LiveActivityContent?) {}

    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await work() }
    }
}

/// A no-op bridge used by unit tests and any host context with no real platform
/// surface. Records the last payloads so tests can assert on them.
@MainActor
public final class NoopPlaybackBridge: PlaybackPlatformBridge {
    public var onRemoteCommand: ((PlaybackRemoteCommand) -> Void)?
    public private(set) var lastNowPlaying: NowPlayingInfo?
    /// `.none` = never set; `.some(nil)` = fallback requested; `.some(data)` = real art.
    public private(set) var lastArtworkData: Data??
    public private(set) var lastLiveActivity: LiveActivityContent?
    /// Every atomic lock-screen submission, in order.
    public private(set) var lockScreenCalls: [(nowPlaying: NowPlayingInfo?, liveActivity: LiveActivityContent?)] = []
    public private(set) var auxiliaryGate = AuxiliaryNowPlayingGate()
    public private(set) var lastAuxiliaryEffect: AuxiliaryNowPlayingGate.Effect?
    /// Simulates the Live Activity reconciliation result for tests.
    public var liveActivityReconciliation: LiveActivityReconciliation = .inactive
    public private(set) var skipBackward: Int?
    public private(set) var skipForward: Int?
    public init() {}
    public func updateNowPlaying(_ info: NowPlayingInfo?) { lastNowPlaying = info }
    public func updateLockScreen(nowPlaying: NowPlayingInfo?, liveActivity: LiveActivityContent?) {
        lockScreenCalls.append((nowPlaying, liveActivity))
        lastNowPlaying = nowPlaying
        lastLiveActivity = liveActivity
    }
    public func updateAuxiliaryNowPlaying(title: String, artist: String) {
        lastAuxiliaryEffect = auxiliaryGate.update(
            AuxiliaryNowPlaying(title: title, artist: artist), reconciliation: liveActivityReconciliation)
    }
    public func clearAuxiliaryNowPlaying() {
        lastAuxiliaryEffect = auxiliaryGate.update(nil, reconciliation: liveActivityReconciliation)
    }
    public func setArtwork(_ imageData: Data?) { lastArtworkData = .some(imageData) }
    public func updateLiveActivity(_ content: LiveActivityContent?) { lastLiveActivity = content }
    public func setSkipIntervals(backward: Int, forward: Int) {
        skipBackward = backward; skipForward = forward
    }
}
