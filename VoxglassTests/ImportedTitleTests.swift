import Testing
@testable import VoxglassCore

@Suite struct ImportedTitleTests {
    @Test func parsesAuthorAndSuffixPresentationOnly() {
        #expect(ImportedTitles.parse("Pride and Prejudice - Jane Austen (Unabridged)") == ImportedTitle(title: "Pride and Prejudice", author: "Jane Austen"))
        #expect(ImportedTitles.parse("Catch 22 Audio book") == ImportedTitle(title: "Catch 22", author: nil))
    }

    @Test func preservesAmbiguousFilename() {
        #expect(ImportedTitles.parse("recording-01") == ImportedTitle(title: "recording-01", author: nil))
    }
}
