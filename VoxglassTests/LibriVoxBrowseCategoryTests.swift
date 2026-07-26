import Testing
@testable import VoxglassCore

@Suite struct LibriVoxBrowseCategoryTests {

    // MARK: - category(withID:)

    @Test func categoryLookupByID() {
        #expect(LibriVoxBrowseCategory.category(withID: "lv-poetry")?.id == "lv-poetry")
        #expect(LibriVoxBrowseCategory.category(withID: "lv-drama-plays")?.id == "lv-drama-plays")
        #expect(LibriVoxBrowseCategory.category(withID: "popular-librivox") == nil)
        #expect(LibriVoxBrowseCategory.category(withID: "not-a-category") == nil)
    }

    // MARK: - subjects parsing

    @Test func subjectsExtractQuotedAndBareTerms() {
        let subjects = LibriVoxBrowseCategory.dramaPlays.subjects.map { $0.lowercased() }
        #expect(subjects.contains("plays"))
        #expect(subjects.contains("dramatic readings"))
        #expect(subjects.contains("drama"))
    }

    @Test func subjectsIgnoreNegatedClause() {
        // philosophyMind has an `AND NOT (subject:poetry OR ...)` tail — those
        // excluded subjects must never be harvested as representative subjects.
        let subjects = LibriVoxBrowseCategory.philosophyMind.subjects.map { $0.lowercased() }
        #expect(subjects.contains("epistemology"))
        #expect(!(subjects.contains("poetry")))
        #expect(!(subjects.contains("romance")))
    }

    @Test func representativeSubjectsAreLimitedAndNonEmpty() {
        let reps = LibriVoxBrowseCategory.horrorGothic.representativeSubjects
        #expect(!(reps.isEmpty))
        #expect(reps.count <= 3)
    }

    // MARK: - category(forSubjects:)

    @Test func genreMappingExactMatch() {
        #expect(LibriVoxBrowseCategory.category(forSubjects: ["Science Fiction"])?.id == "lv-science-fiction")
    }

    @Test func genreMappingDramaFromGreekPlay() {
        // A Greek tragedy imported from archive.org typically carries "plays".
        #expect(LibriVoxBrowseCategory.category(forSubjects: ["Plays", "Tragedy", "Greek"])?.id == "lv-drama-plays")
    }

    @Test func genreMappingReturnsNilForEmpty() {
        #expect(LibriVoxBrowseCategory.category(forSubjects: []) == nil)
    }

    @Test func genreMappingReturnsNilForUnrelatedSubjects() {
        #expect(LibriVoxBrowseCategory.category(forSubjects: ["zzxqywv nonsense token"]) == nil)
    }

    // MARK: - Discovery queries

    @Test func weakCategoryQueriesUseStrictLibriVoxAudioScope() {
        let queries = [
            LibriVoxBrowseCategory.ancientWorld.archiveQuery,
            LibriVoxBrowseCategory.dramaPlays.archiveQuery,
            LibriVoxBrowseCategory.generalFiction.archiveQuery,
            LibriVoxBrowseCategory.mysteryCrime.archiveQuery,
            LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        ]

        for query in queries {
            #expect(query.contains(LibriVoxCatalogScope.collectionClause))
            #expect(query.contains("mediatype:audio"))
            #expect(!(query.contains("audio_bookspoetry")))
        }
    }

    @Test func dramaAndAncientWorldQueriesIncludeSubjectCreatorAndTitleExpansion() {
        let drama = LibriVoxBrowseCategory.dramaPlays.archiveQuery
        #expect(drama.contains("subject:Drama"))
        #expect(drama.contains("creator:\"William Shakespeare\""))
        #expect(drama.contains("title:tragedy"))

        let ancient = LibriVoxBrowseCategory.ancientWorld.archiveQuery
        #expect(ancient.contains("subject:\"Ancient History\""))
        #expect(ancient.contains("creator:Plato"))
        #expect(ancient.contains("creator:Sappho"))
        #expect(!(ancient.contains("title:ancient")))
        #expect(!(ancient.contains("title:roman")))
    }

    @Test func generalFictionMysteryAndEssaysQueriesIncludeBroaderExpansions() {
        let general = LibriVoxBrowseCategory.generalFiction.archiveQuery
        #expect(general.contains("subject:\"General Fiction\""))
        #expect(general.contains("creator:\"Charles Dickens\""))
        #expect(general.contains(LibriVoxCatalogScope.query))
        #expect(!(general.contains("subject:Fiction")))
        #expect(!(general.contains("title:novel")))

        let mystery = LibriVoxBrowseCategory.mysteryCrime.archiveQuery
        #expect(mystery.contains("subject:Mystery"))
        #expect(mystery.contains("title:murder"))
        #expect(mystery.contains("creator:\"Arthur Conan Doyle\""))
        #expect(mystery.contains(LibriVoxCatalogScope.query))

        let essays = LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        #expect(essays.contains("subject:Essays"))
        #expect(essays.contains("creator:\"Ralph Waldo Emerson\""))
        #expect(essays.contains(LibriVoxCatalogScope.query))
        #expect(!(essays.contains("title:lectures")))
        #expect(!(essays.contains("subject:\"Philosophy\"")))
    }

    // MARK: - History backfill weighting

    @Test func historyIncrementFloorsAndCaps() {
        #expect(abs((RecommendationPipeline.historyIncrement(forSeconds: 60)) - (RecommendationConstants.minListenIncrement)) <= 0.0001)
        #expect(abs((RecommendationPipeline.historyIncrement(forSeconds: 3600)) - (1.0)) <= 0.0001)
        #expect(abs((RecommendationPipeline.historyIncrement(forSeconds: 3600 * 100)) - (12.0)) <= 0.0001)
    }
}
