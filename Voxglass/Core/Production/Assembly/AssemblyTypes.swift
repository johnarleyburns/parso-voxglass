import Foundation

public struct PlaybackSegment: Sendable, Equatable, Identifiable {
    public var id: UUID { paragraphID }
    public let paragraphID: UUID
    public let chapterID: UUID
    public let globalOrdinal: Int
    public let assetRef: AudioAssetReference
    public let trim: Range<TimeInterval>
    public let gainDB: Double
    public let fadeIn: TimeInterval
    public let fadeOut: TimeInterval
    public let leadingSilence: TimeInterval
    public let trailingSilence: TimeInterval
    public let text: String
    public let reviewState: ReviewState
    public let isContext: Bool

    public init(
        paragraphID: UUID,
        chapterID: UUID,
        globalOrdinal: Int,
        assetRef: AudioAssetReference,
        trim: Range<TimeInterval>,
        gainDB: Double = 0,
        fadeIn: TimeInterval = 0,
        fadeOut: TimeInterval = 0,
        leadingSilence: TimeInterval = 0,
        trailingSilence: TimeInterval = 0,
        text: String = "",
        reviewState: ReviewState = .unreviewed,
        isContext: Bool = false
    ) {
        self.paragraphID = paragraphID
        self.chapterID = chapterID
        self.globalOrdinal = globalOrdinal
        self.assetRef = assetRef
        self.trim = trim
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.leadingSilence = leadingSilence
        self.trailingSilence = trailingSilence
        self.text = text
        self.reviewState = reviewState
        self.isContext = isContext
    }
}

public enum PlaybackMode: Sendable, Equatable {
    case wholeBook
    case chapter(UUID)
    case selectedChapters(Set<UUID>)
    case flagged
    case needsPickup
    case unapproved
    case reviewQueue(ReviewQueueDefinition)
    case paragraphRange(chapterID: UUID, from: Int, to: Int)
    /// §12.2 retail sample: a gapless run of segments starting at
    /// `startParagraph`, clipped to `maxDuration` (bounded to
    /// `RetailSampleSelection`'s 60…300 s window by the queue builder).
    case retailSample(startParagraph: UUID, maxDuration: TimeInterval)
}
