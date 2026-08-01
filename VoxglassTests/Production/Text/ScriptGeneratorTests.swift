import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct ScriptGeneratorTests {

    @Test func librivoxProducesIntrosAndOutros() {
        let project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator()
        let plan = generator.plan(for: project)

        #expect(!plan.chapterIntros.isEmpty)
        for chapter in project.chapters where chapter.role == .body {
            #expect(plan.chapterIntros[chapter.id] != nil)
            #expect(plan.chapterOutros[chapter.id] != nil)
        }
    }

    @Test func librivoxIntroContainsDisclaimers() {
        let project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator()
        let plan = generator.plan(for: project)

        let firstChapter = project.chapters.first { $0.role == .body }!
        let intro = plan.chapterIntros[firstChapter.id]!

        #expect(intro.contains("LibriVox"))
        #expect(intro.contains("public domain"))
        #expect(intro.contains("librivox dot org"))
        #expect(intro.contains(project.metadata.title))
        #expect(intro.contains(project.metadata.author))
        #expect(intro.contains(project.metadata.narrator))
    }

    @Test func librivoxShortFormUsedAfterFirst() {
        let project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator(useShortFormAfterFirstSection: true)
        let plan = generator.plan(for: project)

        let chapters = project.chapters.filter { $0.role == .body }
        if chapters.count >= 2 {
            let firstIntro = plan.chapterIntros[chapters[0].id]!
            let secondIntro = plan.chapterIntros[chapters[1].id]!

            #expect(firstIntro.contains("For more information"))
            #expect(!secondIntro.contains("For more information"))
        }
    }

    @Test func librivoxOutroContainsEnd() {
        let project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator()
        let plan = generator.plan(for: project)

        let chapters = project.chapters.filter { $0.role == .body }
        if let last = chapters.last, let outro = plan.chapterOutros[last.id] {
            #expect(outro.hasPrefix("End of"))
        }
    }

    @Test func retailProducesCredits() {
        let project = ProjectFixtures.typical()
        let generator = RetailScriptGenerator()
        let plan = generator.plan(for: project)

        #expect(plan.bookChapters.count == 2)
        #expect(plan.bookChapters.contains { $0.role == .openingCredits })
        #expect(plan.bookChapters.contains { $0.role == .closingCredits })
    }

    @Test func retailOpeningCreditsContainsTitle() {
        let project = ProjectFixtures.typical()
        let generator = RetailScriptGenerator()
        let plan = generator.plan(for: project)

        let opening = plan.bookChapters.first { $0.role == .openingCredits }!
        #expect(opening.paragraphText.contains(project.metadata.title))
    }

    @Test func scriptApplierInsertsIntros() {
        var project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator()
        let plan = generator.plan(for: project)

        let applier = ScriptApplier()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let report = applier.apply(plan, to: &project, ids: ids, clock: clock)

        #expect(report.inserted > 0)
    }

    @Test func scriptApplierIdempotent() {
        var project = ProjectFixtures.typical()
        let generator = LibriVoxScriptGenerator()
        let applier = ScriptApplier()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let plan = generator.plan(for: project)
        _ = applier.apply(plan, to: &project, ids: ids, clock: clock)
        let secondReport = applier.apply(plan, to: &project, ids: ids, clock: clock)

        #expect(secondReport.inserted == 0)
        #expect(secondReport.updated == 0)
    }

    @Test func retailScriptApplierAddsChapters() {
        var project = ProjectFixtures.typical()
        let generator = RetailScriptGenerator()
        let plan = generator.plan(for: project)

        let applier = ScriptApplier()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let report = applier.apply(plan, to: &project, ids: ids, clock: clock)

        #expect(report.inserted >= 2)
        #expect(project.chapters.contains { $0.role == .openingCredits })
        #expect(project.chapters.contains { $0.role == .closingCredits })
    }

    @Test func librivoxDestination() {
        #expect(LibriVoxScriptGenerator().destination == .librivox)
    }

    @Test func retailDestination() {
        #expect(RetailScriptGenerator().destination == .acx)
    }
}
