import Foundation
import Testing
@testable import VoxglassCore

@Suite
struct EPUBImporterFixtureTests {
    @Test(arguments: [
        "pride-and-prejudice", // romance / social fiction — Gutenberg #1342
        "frankenstein",         // gothic horror — Gutenberg #84
        "moby-dick",            // adventure — Gutenberg #2701
        "sherlock-holmes"       // detective fiction — Gutenberg #1661
    ])
    func extractsReadableTextFromBundledPopularGutenbergEPUB(_ fixture: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "epub", subdirectory: "EPUB"))
        let document = try await EPUBImporter().extract(from: url)

        #expect(!document.sections.isEmpty, "\(fixture) should produce one or more spine sections")
        #expect(document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count > 1_000,
                "\(fixture) should produce substantial readable text")
    }
}
