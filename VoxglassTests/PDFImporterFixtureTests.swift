import Foundation
import Testing
@testable import VoxglassCore

@Suite
struct PDFImporterFixtureTests {
    @Test(arguments: [
        "supreme-court-hewitt", // Hewitt v. United States, official Supreme Court slip opinion
        "tax-court-jm-assets" // JM Assets, LP v. Commissioner, official Tax Court report
    ])
    func extractsReadableTextFromBundledCourtOpinionPDF(_ fixture: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "pdf", subdirectory: "PDF"))
        let document = try await PDFImporter().extract(from: url)

        #expect(!document.sections.isEmpty, "\(fixture) should produce one or more readable pages")
        #expect(document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count > 1_000,
                "\(fixture) should produce substantial readable text")
    }
}
