import Foundation

public struct RenderPlan: Sendable, Equatable {
    public let chapterID: UUID
    public let segments: [PlaybackSegment]
    public let settings: AssemblySettings
    public let outputFormat: AudioSpec
    public let cacheKey: String

    public init(chapterID: UUID, segments: [PlaybackSegment], settings: AssemblySettings, outputFormat: AudioSpec, cacheKey: String) {
        self.chapterID = chapterID
        self.segments = segments
        self.settings = settings
        self.outputFormat = outputFormat
        self.cacheKey = cacheKey
    }
}

public enum RenderCacheKey {
    public static let algorithmVersion = 1

    public static func key(chapterID: UUID, segments: [PlaybackSegment],
                           settings: AssemblySettings, format: AudioSpec, algorithmVersion: Int = RenderCacheKey.algorithmVersion) -> String {
        var parts: [String] = [
            "v\(algorithmVersion)",
            chapterID.uuidString,
            "\(format.container.rawValue)/\(format.codec.rawValue)/\(format.sampleRate ?? 0)/\(format.channels ?? 0)/\(format.bitrateKbps ?? 0)"
        ]
        parts.append("gap=\(settings.paragraphGap);head=\(settings.chapterHeadSilence);tail=\(settings.chapterTailSilence);scene=\(settings.sceneBreakExtraGap);norm=\(settings.normalizeGapsFromTakeSilence)")

        for s in segments {
            parts.append("\(s.assetRef.sha256)|\(s.trim.lowerBound)|\(s.trim.upperBound)|\(s.gainDB)|\(s.fadeIn)|\(s.fadeOut)|\(s.leadingSilence)|\(s.trailingSilence)")
        }

        return SHA256Hex.hex(joining: parts)
    }
}

public struct ChapterRendering: Sendable {
    public var ref: AudioAssetReference
    public var duration: TimeInterval
    public var paragraphOffsets: [UUID: Range<TimeInterval>]

    public init(ref: AudioAssetReference, duration: TimeInterval, paragraphOffsets: [UUID: Range<TimeInterval>]) {
        self.ref = ref
        self.duration = duration
        self.paragraphOffsets = paragraphOffsets
    }
}

public protocol RenderCache: Sendable {
    func cachedRender(for key: String) async throws -> AudioAssetReference?
    func store(_ ref: AudioAssetReference, for key: String) async throws
}
