import Foundation
import Testing
@testable import VoxglassCore

@Suite
struct EPUBImporterFixtureTests {
    @Test(arguments: [
        "pride-and-prejudice", // romance / social fiction — Gutenberg #1342
        "frankenstein",         // gothic horror — Gutenberg #84
        "moby-dick",            // adventure — Gutenberg #2701
        "sherlock-holmes",      // detective fiction — Gutenberg #1661
        "us-constitution",      // primary legal text — Gutenberg #5
        "federalist-papers",    // legal / political nonfiction — Gutenberg #1404
        "origin-of-species",    // scientific nonfiction — Gutenberg #1228
        "calculus-made-easy"    // technical mathematics — Gutenberg #33283
    ])
    func extractsReadableTextFromBundledPopularGutenbergEPUB(_ fixture: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "epub", subdirectory: "EPUB"))
        let document = try await EPUBImporter().extract(from: url)

        #expect(!document.sections.isEmpty, "\(fixture) should produce one or more spine sections")
        #expect(document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count > 1_000,
                "\(fixture) should produce substantial readable text")
    }
}
