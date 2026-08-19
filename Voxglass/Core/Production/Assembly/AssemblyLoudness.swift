import Foundation

/// Render-time loudness normalization (§11.1, mockup 10 "Normalise take-to-take
/// loudness"). Non-destructive: the gain is carried on the render segment, and
/// the recorded take on disk is never rewritten.
public enum AssemblyLoudness {

    /// The gain, in dB, that brings a take to the ReplayGain reference level.
    ///
    /// `AudioQualityMetrics.replayGainDB` is the gain **to apply**
    /// (`ReplayGainCalculator`: `gainDB = -25.4885 - L95`), so it is added, not
    /// subtracted — the old `-replayGainDB` doubled the deviation instead of
    /// removing it, which is why "Estimated perceived volume out of band" never
    /// went away (field report 2026-08-19, item 13).
    ///
    /// The result is clamped so normalization can never push the take's true
    /// peak past `peakCeilingDBFS`; a take with no usable peak measurement gets
    /// no gain rather than an unbounded one.
    public static func normalizationGainDB(
        for metrics: AudioQualityMetrics,
        peakCeilingDBFS: Double = -1.0
    ) -> Double {
        let requested = metrics.replayGainDB
        guard requested.isFinite, requested != 0 else { return 0 }
        let peak = metrics.truePeakDBFS.isFinite ? metrics.truePeakDBFS : metrics.peakDBFS
        guard peak.isFinite else { return 0 }
        let headroom = peakCeilingDBFS - peak
        return min(requested, headroom)
    }

    /// The perceived volume a take will export at, on the destination's
    /// ReplayGain scale, once `normalizationGainDB` is applied (or as recorded
    /// when normalization is off).
    public static func perceivedVolumeDB(
        for metrics: AudioQualityMetrics,
        target: Double,
        isNormalizing: Bool,
        peakCeilingDBFS: Double = -1.0
    ) -> Double {
        let recorded = target - metrics.replayGainDB
        guard isNormalizing else { return recorded }
        return recorded + normalizationGainDB(for: metrics, peakCeilingDBFS: peakCeilingDBFS)
    }
}
