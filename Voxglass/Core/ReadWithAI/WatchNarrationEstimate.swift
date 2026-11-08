import Foundation

/// Estimates the work needed to turn Read With AI text into a portable Watch
/// audiobook. This is intentionally conservative: voice generation speed
/// varies with the selected system voice and the phone's thermal state.
public enum WatchNarrationEstimate {
    /// Mono HE-AAC target. AAC-LC uses a slightly larger fallback when the
    /// selected device cannot create HE-AAC.
    public static let preferredBitRate = 32_000

    public static func needsGeneratedAudio(for chapters: [Chapter]) -> Bool {
        chapters.contains { $0.localURL?.pathExtension.lowercased() == "voxtext" }
    }

    public static func estimatedAudioBytes(duration: TimeInterval) -> Int64 {
        Int64(max(0, duration) * Double(preferredBitRate) / 8)
    }

    /// A deliberately rounded, pre-flight estimate for offline speech render.
    /// The lower bound avoids promising an instant result for short documents;
    /// the upper bound reflects the work for a full book without pretending to
    /// know the device's installed voice performance.
    public static func estimatedCreationDuration(narrationDuration: TimeInterval) -> TimeInterval {
        min(max(60, max(0, narrationDuration) / 12), 30 * 60)
    }
}
