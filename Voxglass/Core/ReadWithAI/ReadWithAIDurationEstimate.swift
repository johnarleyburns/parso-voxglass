import Foundation

/// A deterministic, on-device duration estimate for system-voice text
/// playback. Keeping it shared by import and playback ensures chapter and book
/// remaining-time displays agree with the speech engine's progress model.
public enum ReadWithAIDurationEstimate {
    public static let charactersPerSecondAtNormalRate = 14.0

    public static func charactersPerSecond(rate: Float = 1) -> Double {
        charactersPerSecondAtNormalRate * Double(min(max(rate, 0.5), 2.0))
    }

    public static func duration(for text: String, rate: Float = 1) -> TimeInterval {
        Double(text.count) / charactersPerSecond(rate: rate)
    }
}
