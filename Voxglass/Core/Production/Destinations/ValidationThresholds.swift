import Foundation

/// Shared thresholds for the validation engine that are NOT destination
/// profile constants (§15). Destination-specific values live in the profiles
/// (`DestinationProfile`), never in `Validation/**` — that is what keeps CI
/// gate G-10 (no magic destination literals outside `DestinationProfiles.swift`
/// / `ValidationThresholds.swift`) enforceable. These are the *analysis*
/// thresholds, common to every destination.
public enum ValidationThresholds {
    /// A take peaking below this is suspiciously quiet (`peakTooLow`).
    public static let peakTooLowDBFS: Double = -24
    /// Linear DC offset above this is a warning (`dcOffset`).
    public static let dcOffsetWarnThreshold: Double = 0.002
    /// A paragraph whose RMS differs from the median of its neighbors by more
    /// than this (dB) is discontinuous (`loudnessDiscontinuity`).
    public static let loudnessDiscontinuityDB: Double = 4
    /// Take duration deviating more than ±60 % from the text estimate flags a
    /// wrong-or-truncated take (`durationOutlier`).
    public static let durationOutlierFraction: Double = 0.6
    /// Speech at the raw file edge (`suspectedTruncation`): the first/last
    /// window of this length must not be this loud.
    public static let truncationEdgeSeconds: TimeInterval = 0.04
    public static let truncationEdgeDBFS: Double = -35
    /// A take with more leading silence than this is excessive (`excessiveLeadingSilence`).
    public static let excessiveLeadingSilenceSeconds: TimeInterval = 2
    /// A chapter longer than this triggers the `chapterVeryLong` recommendation.
    public static let veryLongChapterSeconds: TimeInterval = 3600
    /// Narration-rate estimate used by `durationOutlier` and §9.2 durations:
    /// characters per second approximating 150 wpm English.
    public static let estimatedCharsPerSecond: Double = 14.5
    /// Neighbor window for `loudnessDiscontinuity`: 2 on each side → 4 neighbors.
    public static let discontinuityNeighborWindow = 2
    /// A chapter length below this is exempt from `chapterVeryLong` when the
    /// destination has no hard cap (informational floor; not a rule input).
    public static let informativeChapterSeconds = 300
}
