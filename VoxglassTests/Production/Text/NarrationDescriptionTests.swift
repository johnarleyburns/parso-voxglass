import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// 2026-08-19 field report, item 6: "description is missing when I check my
/// recording, however this was an imported book I was asked to narrate by the
/// Voxglass app so the description should have been pre-filled".
@Suite struct NarrationDescriptionTests {

    @Test func defaultDescriptionNamesTheWorkAuthorAndReader() {
        let description = BookMetadata.defaultDescription(
            title: "Nothing Gold Can Stay", author: "Robert Frost", narrator: "Arley"
        )
        #expect(description.contains("Nothing Gold Can Stay"))
        #expect(description.contains("Robert Frost"))
        #expect(description.contains("Arley"))
    }

    @Test func defaultDescriptionDegradesGracefully() {
        #expect(BookMetadata.defaultDescription(title: "", author: "A", narrator: "B").isEmpty)
        let noReader = BookMetadata.defaultDescription(title: "A Work", author: "An Author", narrator: "  ")
        #expect(noReader == "A Work, by An Author.")
    }

    @Test func aBuiltProjectAlwaysReachesExportWithADescription() {
        let document = ExtractedDocument(
            language: "en-US",
            plainText: "A first paragraph of the work.\n\nA second paragraph of the work."
        )
        let build = NarrationProjectBuilder().build(
            document: document,
            title: "A Short Work",
            author: "An Author",
            narrator: "A Narrator",
            sourceURL: URL(string: "https://example.org/source"),
            ids: SequentialIDGenerator(),
            clock: FixedClock()
        )
        #expect(!build.project.metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let issues = ValidationRuleEngine().evaluate(
            project: build.project,
            metrics: [:],
            profile: DestinationProfile.profile(for: .librivox),
            eligibility: EligibilityProfile.evaluate(build.project),
            assembly: build.project.profile.assembly
        )
        #expect(!issues.contains { $0.code == .missingDescription })
    }

    @Test func aWorkCarriesItsCatalogueSummary() throws {
        let work = NarratableWork(
            title: "A Short Work",
            author: "An Author",
            summary: "A brief blurb from the catalogue.",
            estSeconds: 600,
            sourcePageURL: URL(string: "https://example.org/source")
        )
        #expect(work.summary == "A brief blurb from the catalogue.")

        // Needs persisted before `summary` existed must still decode.
        let legacy = #"{"title":"Old","author":"Someone","lengthClass":"short","grade":"submittable","estSeconds":120}"#
        let decoded = try JSONDecoder().decode(NarratableWork.self, from: Data(legacy.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.title == "Old")
    }
}
