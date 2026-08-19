import Foundation
import Testing
import VoxglassCore

@Suite struct FixActionCoverageTests {
    @Test func everyFixActionHasAHandlerDescription() {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let actions: [FixAction] = [
            .goToParagraph(id), .goToChapter(id), .openMetadata(field: .title), .openRights,
            .recordParagraph(id), .selectTake(paragraphID: id, takeID: id),
            .regenerateDisclaimers, .regenerateCredits, .applyMastering,
            .splitChapter(id, atParagraph: id), .chooseArtwork, .setRetailSample,
            .reanalyzeTake(id), .clearPickup(id), .hydrateAssets, .manageStorage,
            .backupNow, .openAudioSetup, .normalizeLoudness
        ]
        #expect(actions.count == 19)
        #expect(actions.allSatisfy { !handlerDescription(for: $0).isEmpty })
    }

    private func handlerDescription(for action: FixAction) -> String {
        switch action {
        case .goToParagraph: "open paragraph review"
        case .goToChapter: "open chapter review"
        case .openMetadata: "open metadata"
        case .openRights: "open rights"
        case .recordParagraph: "record paragraph"
        case .selectTake: "select take"
        case .regenerateDisclaimers: "regenerate disclaimers"
        case .regenerateCredits: "regenerate credits"
        case .applyMastering: "apply mastering"
        case .splitChapter: "split chapter"
        case .chooseArtwork: "choose artwork"
        case .setRetailSample: "set sample"
        case .reanalyzeTake: "reanalyze take"
        case .clearPickup: "clear pickup"
        case .hydrateAssets: "hydrate assets"
        case .manageStorage: "manage storage"
        case .backupNow: "back up"
        case .openAudioSetup: "open audio setup"
        case .normalizeLoudness: "normalize loudness"
        }
    }
}
