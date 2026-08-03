import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct IASourceTests {

    let source = InternetArchiveNeedsSource(currentYear: 2026)

    @Test func pre1930EditionIsIAVerifiedAndSubmittable() throws {
        let json = """
        { "response": { "numFound": 1, "docs": [
          { "identifier": "gutenberg-book-1", "title": "Old Book", "creator": "Old Author", "year": 1920 }
        ] } }
        """
        let docs = try source.decodeTexts(Data(json.utf8))
        let needs = docs.map { $0.toNeed(now: FixedClock().now, currentYear: 2026, recordedSet: []) }
        let need = needs.first!
        #expect(need.provenance.pdBasis == .iaVerifiedEdition)
        #expect(need.provenance.editionYear == 1920)
        #expect(need.isSubmittable)
        #expect(need.work.sourcePageURL?.path == "/details/gutenberg-book-1")
    }

    @Test func recentEditionDegradesToPractice() throws {
        let json = """
        { "response": { "numFound": 1, "docs": [
          { "identifier": "recent-book", "title": "Recent Book", "creator": "Modern", "year": 2001 }
        ] } }
        """
        let docs = try source.decodeTexts(Data(json.utf8))
        let need = docs[0].toNeed(now: FixedClock().now, currentYear: 2026, recordedSet: [])
        #expect(need.provenance.pdBasis == .unverified)
        #expect(need.work.grade == .practice)
    }

    @Test func unrecordedTitleRaisesCatalogGap() throws {
        let need = IADoc(identifier: "x", title: "Unrecorded Classic", creator: "Author", year: 1900)
            .toNeed(now: FixedClock().now, currentYear: 2026, recordedSet: ["Something Else"])
        #expect(need.signal == .catalogGap)
    }

    @Test func recordedTitleIsEvergreen() throws {
        // `toNeed` receives the already-normalized recorded set (the source
        // normalizes via NeedID before building it); raw titles normalize the same.
        let need = IADoc(identifier: "x", title: "Recorded Classic", creator: "Author", year: 1900)
            .toNeed(now: FixedClock().now, currentYear: 2026, recordedSet: ["recorded classic"])
        #expect(need.signal == .evergreen)
    }

    @Test func decodeRecordedReturnsTitles() throws {
        let json = """
        { "response": { "numFound": 2, "docs": [
          { "identifier": "lv1", "title": "Poem One" },
          { "identifier": "lv2", "title": "Poem Two" }
        ] } }
        """
        let titles = try source.decodeRecorded(Data(json.utf8))
        #expect(titles == ["Poem One", "Poem Two"])
    }
}
