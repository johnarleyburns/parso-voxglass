import Foundation

/// Every validation rule in §15.3. One test per code (see
/// `ValidationRuleEngineTests`), grouped below in the spec's five groups.
/// Severities are a function of destination and are decided by the engine,
/// never by this enum.
public enum IssueCode: String, Sendable, Codable, CaseIterable {
    // MARK: Group 1 — Metadata and rights

    case missingTitle
    case missingAuthor
    case missingNarrator
    case missingLanguage
    case missingDescription
    case missingSourceURL
    case missingRightsBasis
    case personalRightsForPublicTarget
    case unattestedRights
    case missingCoverArt
    case artworkTooSmall
    case artworkNotSquare
    case missingCopyrightYear
    case missingPublisher
    case missingArchiveIdentifier
    case invalidArchiveIdentifier

    // MARK: Group 2 — Narration origin and eligibility

    case aiOriginInLibriVoxProject
    case unknownOriginTakeSelected
    case undisclosedAINarration

    // MARK: Group 3 — Completeness and structure

    case missingAcceptedTake
    case unresolvedNeedsPickup
    case unapprovedParagraphs
    case textChangedAfterRecording
    case textChangedCosmetically
    case emptyChapter
    case duplicateOrdinal
    case missingOrdinal
    case assetMissing
    case assetHashMismatch
    case missingDisclaimerParagraph
    case unrecordedDisclaimer
    case staleDisclaimerText
    case missingOpeningCredits
    case missingClosingCredits
    case missingRetailSample
    case retailSampleTooShort
    case retailSampleTooLong
    case retailSampleStartsInCredits
    case chapterTooLong
    case chapterVeryLong

    // MARK: Group 4 — Audio quality

    case clipping
    case peakTooHot
    case peakTooLow
    case rmsOutOfRange
    case noiseFloorTooHigh
    case noiseFloorUnreliable
    case dcOffset
    case sampleRateMismatch
    case channelInconsistency
    case stereoWhereMonoExpected
    case bitDepthMismatch
    case loudnessDiscontinuity
    case durationOutlier
    case suspectedTruncation
    case excessiveLeadingSilence
    case headRoomToneOutOfRange
    case tailRoomToneOutOfRange
    case missingMetrics

    // MARK: Group 5 — Loudness (LibriVox)

    case perceivedVolumeOutOfBand
}
