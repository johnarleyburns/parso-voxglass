import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct EligibilityProfileTests {

    @Test func humanOnlyProjectIsLibrivoxEligible() {
        let project = ProjectFixtures.tiny()
        let profile = EligibilityProfile.evaluate(project)
        #expect(profile.narrationOrigin == .humanOnly)
        #expect(profile.librivoxEligible == true)
        #expect(profile.aiParagraphIDs.isEmpty)
        #expect(profile.aiParagraphCount == 0)
    }

    @Test func selectedImportedAIMakesProjectIneligible() {
        let project = ProjectFixtures.aiTainted()
        let profile = EligibilityProfile.evaluate(project)
        #expect(profile.narrationOrigin == .containsImportedAI)
        #expect(profile.librivoxEligible == false)
        #expect(!profile.aiParagraphIDs.isEmpty)
        #expect(profile.aiParagraphCount == 1)
        #expect(profile.humanParagraphCount == 0)
    }

    @Test func unselectedAIDoesNotTaintProject() {
        let project = ProjectFixtures.aiUnselected()
        let profile = EligibilityProfile.evaluate(project)
        #expect(profile.narrationOrigin == .humanOnly)
        #expect(profile.librivoxEligible == true)
        #expect(profile.aiParagraphIDs.isEmpty)
        #expect(profile.aiParagraphCount == 0)
    }

    @Test func emptyProjectIsEligible() {
        let ids = SequentialIDGenerator()
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Empty", author: "A", narrator: "N")
        )
        let profile = EligibilityProfile.evaluate(project)
        #expect(profile.narrationOrigin == .humanOnly)
        #expect(profile.librivoxEligible == true)
    }

    @Test func aiParagraphIDListedCorrectly() {
        let project = ProjectFixtures.aiTainted()
        let profile = EligibilityProfile.evaluate(project)
        if let paraID = project.allParagraphs.first?.id {
            #expect(profile.aiParagraphIDs.contains(paraID))
        }
    }
}
