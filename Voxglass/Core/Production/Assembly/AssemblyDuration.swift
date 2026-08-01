import Foundation

/// Timing computed from a chapter's segments **without** rendering audio.
///
/// Spec §12.4 / §15.4: assembly-derived durations are the sum of the trimmed
/// take durations plus the configured leading/trailing silence, evaluated in
/// one pass over the segments. The renderer and the validation engine both use
/// this so their answers can never disagree.
///
/// The silence model mirrors `SegmentQueueBuilder`: `leadingSilence` precedes
/// a segment's audio and `trailingSilence` follows it. For whole-book playback
/// the inter-paragraph gap is carried by the next segment's `leadingSilence`
/// (interior `trailingSilence` is 0); review modes carry the tight 0.25 s
/// turnaround on `trailingSilence` instead. Either way, offsets accumulate as
/// `cursor += leading + audio + trailing`.
public struct AssemblyTiming: Sendable, Equatable {
    /// Start of each paragraph's audio within the assembled chapter, in seconds.
    public var paragraphStart: [UUID: TimeInterval]
    /// End of each paragraph's audio within the assembled chapter, in seconds.
    public var paragraphEnd: [UUID: TimeInterval]
    /// Total assembled duration, including all inserted silence.
    public var totalDuration: TimeInterval

    public init(
        paragraphStart: [UUID: TimeInterval] = [:],
        paragraphEnd: [UUID: TimeInterval] = [:],
        totalDuration: TimeInterval = 0
    ) {
        self.paragraphStart = paragraphStart
        self.paragraphEnd = paragraphEnd
        self.totalDuration = totalDuration
    }
}

public enum AssemblyDuration {
    /// Compute per-paragraph offsets and the total duration for the given
    /// segments, which MUST be in playback order.
    public static func compute(segments: [PlaybackSegment]) -> AssemblyTiming {
        var start: [UUID: TimeInterval] = [:]
        var end: [UUID: TimeInterval] = [:]
        var cursor: TimeInterval = 0

        for segment in segments {
            let trimmed = max(0, segment.trim.upperBound - segment.trim.lowerBound)
            let offset = cursor + segment.leadingSilence
            start[segment.paragraphID] = offset
            end[segment.paragraphID] = offset + trimmed
            cursor = offset + trimmed + segment.trailingSilence
        }

        return AssemblyTiming(
            paragraphStart: start,
            paragraphEnd: end,
            totalDuration: cursor
        )
    }

    /// Total assembled duration for the given segments.
    public static func duration(of segments: [PlaybackSegment]) -> TimeInterval {
        compute(segments: segments).totalDuration
    }
}
