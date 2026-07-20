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
        XCTAssertTrue(subjects.contains("drama"))
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

    func testWeakCategoryQueriesUseStrictLibriVoxAudioScope() {
        let queries = [
            LibriVoxBrowseCategory.ancientWorld.archiveQuery,
            LibriVoxBrowseCategory.dramaPlays.archiveQuery,
            LibriVoxBrowseCategory.generalFiction.archiveQuery,
            LibriVoxBrowseCategory.mysteryCrime.archiveQuery,
            LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        ]

        for query in queries {
            XCTAssertTrue(query.contains(LibriVoxCatalogScope.collectionClause))
            XCTAssertTrue(query.contains("mediatype:audio"))
            XCTAssertFalse(query.contains("audio_bookspoetry"))
        }
    }

    func testDramaAndAncientWorldQueriesIncludeSubjectCreatorAndTitleExpansion() {
        let drama = LibriVoxBrowseCategory.dramaPlays.archiveQuery
        XCTAssertTrue(drama.contains("subject:Drama"))
        XCTAssertTrue(drama.contains("creator:\"William Shakespeare\""))
        XCTAssertTrue(drama.contains("title:tragedy"))

        let ancient = LibriVoxBrowseCategory.ancientWorld.archiveQuery
        XCTAssertTrue(ancient.contains("subject:\"Ancient History\""))
        XCTAssertTrue(ancient.contains("creator:Plato"))
        XCTAssertTrue(ancient.contains("creator:Sappho"))
        XCTAssertFalse(ancient.contains("title:ancient"))
        XCTAssertFalse(ancient.contains("title:roman"))
    }

    func testGeneralFictionMysteryAndEssaysQueriesIncludeBroaderExpansions() {
        let general = LibriVoxBrowseCategory.generalFiction.archiveQuery
        XCTAssertTrue(general.contains("subject:\"General Fiction\""))
        XCTAssertTrue(general.contains("creator:\"Charles Dickens\""))
        XCTAssertTrue(general.contains(LibriVoxCatalogScope.query))
        XCTAssertFalse(general.contains("subject:Fiction"))
        XCTAssertFalse(general.contains("title:novel"))

        let mystery = LibriVoxBrowseCategory.mysteryCrime.archiveQuery
        XCTAssertTrue(mystery.contains("subject:Mystery"))
        XCTAssertTrue(mystery.contains("title:murder"))
        XCTAssertTrue(mystery.contains("creator:\"Arthur Conan Doyle\""))
        XCTAssertTrue(mystery.contains(LibriVoxCatalogScope.query))

        let essays = LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        XCTAssertTrue(essays.contains("subject:Essays"))
        XCTAssertTrue(essays.contains("creator:\"Ralph Waldo Emerson\""))
        XCTAssertTrue(essays.contains(LibriVoxCatalogScope.query))
        XCTAssertFalse(essays.contains("title:lectures"))
        XCTAssertFalse(essays.contains("subject:\"Philosophy\""))
    }

    // MARK: - History backfill weighting

    func testHistoryIncrementFloorsAndCaps() {
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 60), RecommendationConstants.minListenIncrement, accuracy: 0.0001)
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 3600), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 3600 * 100), 12.0, accuracy: 0.0001)
    }
}
