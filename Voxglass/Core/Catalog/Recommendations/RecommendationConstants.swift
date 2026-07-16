import Foundation

public enum RecommendationConstants {
    public static let tau: Double = 21 * 86400
    public static let favoriteBoost: Double = 3.0
    public static let classMix: (exploit: Double, explore: Double, serendipity: Double) = (0.55, 0.35, 0.10)
    public static let wAffinity: Double = 0.55
    public static let wNovelty: Double = 0.35
    public static let wPop: Double = 0.10
    public static let lambdaMMR: Double = 0.5
    public static let kTarget: Int = 24
    public static let minShelf: Int = 10
    public static let onboardingSeedWeight: Double = 1.75
    public static let recoSurfacedCap: Int = 500
    public static let downloadFloor: Int = 200
    /// Minimum fraction of a book that must be listened to before playback
    /// contributes to the taste profile (unless the book is finished).
    public static let meaningfulListenCompletion: Double = 0.20

    public static let subjectStopList: Set<String> = [
        "music", "audio", "spoken word", "librivox", "podcast",
        "sound", "recording", "mp3", "ogg", "stream", "broadcast"
    ]
}
