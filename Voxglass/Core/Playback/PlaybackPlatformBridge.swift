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

    /// Sets the lock-screen artwork from raw image bytes. `nil` selects the
    /// app's bundled fallback artwork.
    func setArtwork(_ imageData: Data?)

    /// Updates the preferred skip intervals surfaced on the remote command center.
    func setSkipIntervals(backward: Int, forward: Int)

    /// Wraps an async position flush in a background-task assertion so an OS kill
    /// can't drop the enqueued write. The default just runs the work.
    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void)
}

public extension PlaybackPlatformBridge {
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
    public private(set) var skipBackward: Int?
    public private(set) var skipForward: Int?
    public init() {}
    public func updateNowPlaying(_ info: NowPlayingInfo?) { lastNowPlaying = info }
    public func setArtwork(_ imageData: Data?) { lastArtworkData = .some(imageData) }
    public func setSkipIntervals(backward: Int, forward: Int) {
        skipBackward = backward; skipForward = forward
    }
}
