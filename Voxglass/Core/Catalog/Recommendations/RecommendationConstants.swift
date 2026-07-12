import Foundation

enum RecommendationConstants {
    static let tau: Double = 21 * 86400
    static let favoriteBoost: Double = 3.0
    static let classMix: (exploit: Double, explore: Double, serendipity: Double) = (0.55, 0.35, 0.10)
    static let wAffinity: Double = 0.55
    static let wNovelty: Double = 0.35
    static let wPop: Double = 0.10
    static let lambdaMMR: Double = 0.5
    static let kTarget: Int = 24
    static let minShelf: Int = 10
    static let onboardingSeedWeight: Double = 1.75
    static let recoSurfacedCap: Int = 500
    static let downloadFloor: Int = 200

    static let subjectStopList: Set<String> = [
        "music", "audio", "spoken word", "librivox", "podcast",
        "sound", "recording", "mp3", "ogg", "stream", "broadcast"
    ]
}
