import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// 2026-08-19 field report, item 5: "after Check My Recording, I see two
/// duplicate regenerate errors". The intro and the outro each emitted
/// `staleDisclaimerText` with the same title and the same message, so one
/// legitimate pair read as one duplicated error.
@Suite struct DisclaimerIssueIdentityTests {

    private func libriVoxProject() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let now = clock.now
        let body = (0..<2).map { index -> Paragraph in
            let text = "Body paragraph \(index)."
            return Paragraph(id: ids.next(), ordinal: index, text: text,
                             textHash: TextNormalizer.hash(text), role: .body, updatedAt: now)
        }
        var project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "A Short Work", author: "An Author", narrator: "A Narrator", language: "en-US"),
            rights: RightsEvidence(basis: .publicDomainUS, sourceURL: URL(string: "https://example.org/source")),
            profile: ProductionProfile(purpose: .publicDomainCommunity, recording: RecordingDefaults(), intendedDestination: .librivox),
            source: nil,
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter One", role: .body, paragraphs: body)],
            createdAt: now,
            modifiedAt: now
        )
        _ = ScriptApplier().apply(LibriVoxScriptGenerator().plan(for: project), to: &project, ids: ids, clock: clock)
        return project
    }

    private func issues(_ project: AudiobookProject, destination: DestinationID) -> [ValidationIssue] {
        ValidationRuleEngine().evaluate(
            project: project,
            metrics: [:],
            profile: DestinationProfile.profile(for: destination),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly
        )
    }

    @Test func staleIntroAndOutroAreTwoDistinguishableIssues() {
        var project = libriVoxProject()
        // The title appears in both the intro and the outro script, so editing
        // it is what makes the pair go stale together. (The narrator appears in
        // the intro only.)
        project.metadata.title = "A Short Work (Revised)"

        let stale = issues(project, destination: .librivox).filter { $0.code == .staleDisclaimerText }
        #expect(stale.count == 2)
        #expect(Set(stale.map(\.id)).count == 2, "two issues may never share an Identifiable id")
        #expect(Set(stale.map(\.title)).count == 2, "the intro and outro must be told apart")
        #expect(Set(stale.map(\.message)).count == 2)
        #expect(stale.contains { $0.title.localizedCaseInsensitiveContains("intro") })
        #expect(stale.contains { $0.title.localizedCaseInsensitiveContains("outro") })
    }

    @Test func noEvaluationEverReturnsTwoIssuesSharingAnID() {
        var project = ProjectFixtures.typical()
        project.metadata.description = ""
        project.metadata.narrator = ""
        for destination in [DestinationID.librivox, .internetArchive, .acx, .appleBooksAggregator, .personalMaster] {
            let all = issues(project, destination: destination)
            #expect(Set(all.map(\.id)).count == all.count,
                    "\(destination) produced duplicate issue ids")
        }
    }

    @Test func missingDisclaimersStayDistinctPerPart() {
        var project = libriVoxProject()
        project.chapters[0].paragraphs.removeAll { $0.role == .libriVoxIntro || $0.role == .libriVoxOutro }

        let missing = issues(project, destination: .librivox).filter { $0.code == .missingDisclaimerParagraph }
        #expect(missing.count == 2)
        #expect(Set(missing.map(\.id)).count == 2)
    }
}
