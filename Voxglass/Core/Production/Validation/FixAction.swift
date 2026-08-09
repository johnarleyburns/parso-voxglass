import Foundation

/// A mechanical remedy for a `ValidationIssue` (§15.2). Every issue that has a
/// fix MUST carry one; the Validation screen's "Fix Next Issue" walks blocking
/// issues in document order and performs or navigates the action.
public enum FixAction: Sendable, Equatable, Codable {
    case goToParagraph(UUID)
    case goToChapter(UUID)
    case openMetadata(field: MetadataField)
    case openRights
    case recordParagraph(UUID)
    case selectTake(paragraphID: UUID, takeID: UUID)
    case regenerateDisclaimers
    case regenerateCredits
    case applyMastering
    case splitChapter(UUID, atParagraph: UUID)
    case chooseArtwork
    case setRetailSample
    case reanalyzeTake(UUID)
    case clearPickup(UUID)
    case hydrateAssets
    case manageStorage
    case backupNow
    case openAudioSetup
}
