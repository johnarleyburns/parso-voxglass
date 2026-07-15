import XCTest
@testable import VoxglassCore

final class LibriVoxBrowseCategoryTests: XCTestCase {

    // MARK: - category(withID:)

    func testCategoryLookupByID() {
        XCTAssertEqual(LibriVoxBrowseCategory.category(withID: "lv-poetry")?.id, "lv-poetry")
        XCTAssertEqual(LibriVoxBrowseCategory.category(withID: "lv-drama-plays")?.id, "lv-drama-plays")
        XCTAssertNil(LibriVoxBrowseCategory.category(withID: "popular-librivox"))
        XCTAssertNil(LibriVoxBrowseCategory.category(withID: "not-a-category"))
    }

    // MARK: - subjects parsing

    func testSubjectsExtractQuotedAndBareTerms() {
        let subjects = LibriVoxBrowseCategory.dramaPlays.subjects.map { $0.lowercased() }
        XCTAssertTrue(subjects.contains("plays"))
        XCTAssertTrue(subjects.contains("dramatic readings"))
    }

    func testSubjectsIgnoreNegatedClause() {
        // philosophyMind has an `AND NOT (subject:poetry OR ...)` tail — those
        // excluded subjects must never be harvested as representative subjects.
        let subjects = LibriVoxBrowseCategory.philosophyMind.subjects.map { $0.lowercased() }
        XCTAssertTrue(subjects.contains("epistemology"))
        XCTAssertFalse(subjects.contains("poetry"))
        XCTAssertFalse(subjects.contains("romance"))
    }

    func testRepresentativeSubjectsAreLimitedAndNonEmpty() {
        let reps = LibriVoxBrowseCategory.horrorGothic.representativeSubjects
        XCTAssertFalse(reps.isEmpty)
        XCTAssertLessThanOrEqual(reps.count, 3)
    }

    // MARK: - category(forSubjects:)

    func testGenreMappingExactMatch() {
        XCTAssertEqual(
            LibriVoxBrowseCategory.category(forSubjects: ["Science Fiction"])?.id,
            "lv-science-fiction"
        )
    }

    func testGenreMappingDramaFromGreekPlay() {
        // A Greek tragedy imported from archive.org typically carries "plays".
        XCTAssertEqual(
            LibriVoxBrowseCategory.category(forSubjects: ["Plays", "Tragedy", "Greek"])?.id,
            "lv-drama-plays"
        )
    }

    func testGenreMappingReturnsNilForEmpty() {
        XCTAssertNil(LibriVoxBrowseCategory.category(forSubjects: []))
    }

    func testGenreMappingReturnsNilForUnrelatedSubjects() {
        XCTAssertNil(LibriVoxBrowseCategory.category(forSubjects: ["zzxqywv nonsense token"]))
    }

    // MARK: - Discovery queries

    func testAuthorQueryScopesToLibriVoxAudio() {
        let query = NowPlayingView.authorQuery("Arthur Conan Doyle")
        XCTAssertTrue(query.contains("creator:\"Arthur Conan Doyle\""))
        XCTAssertTrue(query.contains("collection:librivoxaudio"))
        XCTAssertTrue(query.contains("mediatype:audio"))
    }

    func testAuthorQueryStripsQuotes() {
        let query = NowPlayingView.authorQuery("O\"Brien")
        XCTAssertFalse(query.dropFirst("creator:\"".count).contains("\"\""))
    }

    func testNarratorQueryMatchesCreatorOrDescription() {
        let query = NowPlayingView.narratorQuery("Ruth Golding")
        XCTAssertTrue(query.contains("creator:\"Ruth Golding\""))
        XCTAssertTrue(query.contains("description:\"Ruth Golding\""))
    }

    func testGenreQueryAppendsMediatypeWhenMissing() {
        let category = LibriVoxBrowseCategory.romance
        XCTAssertFalse(category.archiveQuery.contains("mediatype:"))
        XCTAssertTrue(NowPlayingView.genreQuery(category).contains("mediatype:audio"))
    }

    // MARK: - History backfill weighting

    func testHistoryIncrementFloorsAndCaps() {
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 60), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 3600), 1.0, accuracy: 0.0001)
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 3600 * 100), 12.0, accuracy: 0.0001)
    }
}
