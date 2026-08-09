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

    // MARK: Group 6 — iPhone preflight (§12.2)

    /// Export cannot start until the listed assets hydrate; carries the byte
    /// estimate. Blocking-for-export only, never a quality failure.
    case assetRemoteOnlyForExport
    /// Export is blocked until the user frees space or reduces scope; carries
    /// required vs available bytes.
    case localStorageInsufficient
    /// A long project still has `localOnly` originals that have never verified
    /// against iCloud (§6.1).
    case backupNotVerified
    /// Selected takes were recorded on `draftOnly` routes (§7.1); retail
    /// readiness is computed from the recorded route history, not the route at
    /// export time.
    case routeNotRetailReady
}
