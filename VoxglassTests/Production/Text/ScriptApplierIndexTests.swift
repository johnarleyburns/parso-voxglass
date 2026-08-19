import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Regressions for the 2026-08-19 field report, item 11: "Regenerate" never
/// cleared `staleDisclaimerText`, because the applier resolved the outro's
/// index against a chapter snapshot taken *before* the intro was inserted — so
/// the outro script overwrote the preceding, recorded, body paragraph.
@Suite struct ScriptApplierIndexTests {

    private func project(chapterTitle: String = "Nothing Gold Can Stay") -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let now = clock.now
        var body: [Paragraph] = []
        for index in 0..<3 {
            let text = "Body paragraph \(index)."
            body.append(Paragraph(
                id: ids.next(), ordinal: index, text: text,
                textHash: TextNormalizer.hash(text), role: .body, updatedAt: now
            ))
        }
        var project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Nothing Gold Can Stay", author: "Robert Frost", narrator: "Test Narrator", language: "en-US"),
            rights: RightsEvidence(basis: .publicDomainUS, sourceURL: URL(string: "https://example.org/source")),
            profile: ProductionProfile(purpose: .publicDomainCommunity, recording: RecordingDefaults(), intendedDestination: .librivox),
            source: nil,
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: chapterTitle, role: .body, paragraphs: body)],
            createdAt: now,
            modifiedAt: now
        )
        _ = ScriptApplier().apply(LibriVoxScriptGenerator().plan(for: project), to: &project, ids: ids, clock: clock)
        return project
    }

    private func applyLibriVox(to project: inout AudiobookProject) -> ScriptApplyReport {
        ScriptApplier().apply(
            LibriVoxScriptGenerator().plan(for: project),
            to: &project,
            ids: SequentialIDGenerator(),
            clock: FixedClock()
        )
    }

    private func staleIssues(_ project: AudiobookProject) -> [ValidationIssue] {
        ValidationRuleEngine().evaluate(
            project: project,
            metrics: [:],
            profile: DestinationProfile.profile(for: .librivox),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly
        ).filter { $0.code == .staleDisclaimerText }
    }

    @Test func insertingAMissingIntroDoesNotOverwriteABodyParagraph() {
        var project = project()
        project.chapters[0].paragraphs.removeAll { $0.role == .libriVoxIntro }
        let outroIndex = project.chapters[0].paragraphs.firstIndex { $0.role == .libriVoxOutro }!
        project.chapters[0].paragraphs[outroIndex].text = "STALE OUTRO"

        _ = applyLibriVox(to: &project)

        let bodies = project.chapters[0].paragraphs.filter { $0.role == .body }
        #expect(bodies.count == 3, "no body paragraph may be consumed by the disclaimer write")
        #expect(bodies.allSatisfy { $0.text.hasPrefix("Body paragraph") },
                "a body paragraph was overwritten with disclaimer text")

        let outros = project.chapters[0].paragraphs.filter { $0.role == .libriVoxOutro }
        #expect(outros.count == 1)
        #expect(outros[0].text.hasPrefix("End of"), "the outro script must land on the outro paragraph")
    }

    @Test func regeneratingClearsStaleDisclaimersInOnePass() {
        var project = project()
        project.chapters[0].paragraphs.removeAll { $0.role == .libriVoxIntro }
        let outroIndex = project.chapters[0].paragraphs.firstIndex { $0.role == .libriVoxOutro }!
        project.chapters[0].paragraphs[outroIndex].text = "STALE OUTRO"

        _ = applyLibriVox(to: &project)

        #expect(staleIssues(project).isEmpty, "one Regenerate must clear the block, not zero of them")
    }

    @Test func applyingTwiceIsAFixpoint() {
        var project = project()
        project.metadata.title = "Nothing Gold Can Stay (Revised)"
        #expect(staleIssues(project).count == 2, "the intro and the outro each go stale")

        _ = applyLibriVox(to: &project)
        #expect(staleIssues(project).isEmpty)

        let second = applyLibriVox(to: &project)
        #expect(second.updated == 0, "a second apply of the same plan must change nothing")
        #expect(second.inserted == 0)
    }

    @Test func regeneratingCreditsRewritesAnExistingCreditsChapter() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        var project = ProjectFixtures.typical()
        project.profile.intendedDestination = .acx
        _ = ScriptApplier().apply(RetailScriptGenerator().plan(for: project), to: &project, ids: ids, clock: clock)

        let openingIndex = project.chapters.firstIndex { $0.role == .openingCredits }!
        project.chapters[openingIndex].paragraphs[0].text = "STALE OPENING CREDITS"
        project.metadata.narrator = "A Different Narrator"

        let expected = RetailScriptGenerator().plan(for: project).bookChapters
            .first { $0.role == .openingCredits }!.paragraphText
        let report = ScriptApplier().apply(
            RetailScriptGenerator().plan(for: project), to: &project, ids: ids, clock: clock
        )

        let opening = project.chapters.first { $0.role == .openingCredits }!.paragraphs[0]
        #expect(opening.text == expected, "regenerate credits must actually write the new text")
        #expect(opening.textHash == TextNormalizer.hash(expected))
        #expect(report.updated >= 1)

        let second = ScriptApplier().apply(
            RetailScriptGenerator().plan(for: project), to: &project, ids: ids, clock: clock
        )
        #expect(second.updated == 0, "retail credits must reach a fixpoint too")
    }
}
