import XCTest
@testable import VoxglassCore

final class RecommendationPipelineTests: XCTestCase {

    // MARK: - Empty everything

    func testEmptyEverythingReturnsBundledPopularSeeds() {
        let recs = RecommendationPipeline.recommendations(
            history: [],
            onboardingSelectionIDs: [],
            candidates: []
        )
        let seedIDs = Set(HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
        XCTAssertFalse(recs.isEmpty)
        XCTAssertTrue(recs.allSatisfy { seedIDs.contains($0.identifier) }, "All recommendations should be from bundled popular seeds")
    }

    func testEmptyEverythingExcludesGivenKeys() {
        let excludeKeys: Set<String> = ["pride_and_prejudice_librivox", "ia:pride_and_prejudice_librivox"]
        let recs = RecommendationPipeline.recommendations(
            history: [],
            onboardingSelectionIDs: [],
            candidates: [],
            excludeKeys: excludeKeys
        )
        XCTAssertFalse(recs.contains { $0.identifier == "pride_and_prejudice_librivox" })
        XCTAssertFalse(recs.isEmpty)
    }

    // MARK: - Early listener, one meaningful listen

    func testOneMeaningfulListenTopsProfile() {
        let entry = ListeningHistoryEntry(
            authors: ["Mary Shelley"],
            subjects: ["Gothic Fiction"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        XCTAssertFalse(profile.isEmpty)
        XCTAssertEqual(profile.topCreators.first, "mary shelley")
    }

    func testOneMeaningfulListenGeneratesExploitQuery() {
        let entry = ListeningHistoryEntry(
            authors: ["Aristophanes"],
            subjects: ["Drama"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        XCTAssertTrue(queries.contains { $0.iaQuery.contains("creator:\"aristophanes\"") })
    }

    func testOneMeaningfulListenBeatsBundledFallback() {
        let entry = ListeningHistoryEntry(
            authors: ["Mary Shelley"],
            subjects: ["Gothic Fiction"],
            listenedSeconds: 7200
        )
        let matched = candidate("match", "Frankenstein", "Mary Shelley", subjects: ["Gothic Fiction"])
        let recs = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: [],
            candidates: [matched, candidate("other", "Other Book", "Someone Else")]
        )
        XCTAssertFalse(recs.isEmpty)
        XCTAssertFalse(recs.map(\.identifier) == HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
        XCTAssertTrue(recs.contains { $0.identifier == "match" })
    }

    // MARK: - One listen + onboarding

    func testListenedAuthorOutranksOnboardingAuthors() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Romance"],
            listenedSeconds: 1800 // 30 min -> floors at minListenIncrement
        )
        let profile = RecommendationPipeline.buildProfile(
            history: [entry],
            onboardingSelectionIDs: ["great-books"]
        )
        let creators = profile.creatorTerms
        XCTAssertFalse(creators.isEmpty)
        let janeAusten = creators.first { $0.term == "jane austen" }
        let onboardingAuthors = creators.filter { $0.weight == RecommendationConstants.onboardingAuthorSeedWeight }
        if let ja = janeAusten {
            for oa in onboardingAuthors {
                XCTAssertGreaterThan(ja.weight, oa.weight,
                    "listened author should outrank onboarding authors (minListenIncrement > onboardingAuthorSeedWeight)")
            }
        }
    }

    // MARK: - Onboarding-only

    func testOnboardingOnlyBrowsePickProducesNonEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["lv-mystery-crime"]
        )
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.subjectTerms.isEmpty)
    }

    func testOnboardingOnlyCuratedPickProducesNonEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["great-books"]
        )
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.creatorTerms.isEmpty)
    }

    func testPopularLibrivoxOnlyOnboardingProducesEmptyProfile() {
        let profile = RecommendationPipeline.buildProfile(
            history: [],
            onboardingSelectionIDs: ["popular-librivox"]
        )
        XCTAssertTrue(profile.isEmpty)
    }

    // MARK: - Long-time listener shape

    func testLongTimeListenerProfileOrdersCorrectly() {
        let finished1 = ListeningHistoryEntry(
            authors: ["Homer"],
            subjects: ["Epic Poetry"],
            languages: ["eng"],
            listenedSeconds: 28800 // 8h
        )
        let finished2 = ListeningHistoryEntry(
            authors: ["Plato"],
            subjects: ["Philosophy"],
            languages: ["eng"],
            listenedSeconds: 28800 // 8h
        )
        let mostlyFinished = ListeningHistoryEntry(
            authors: ["Sophocles"],
            subjects: ["Drama"],
            languages: ["eng"],
            listenedSeconds: 25200 // 70% of 10h
        )
        let barelyTouched = (0..<9).map { i in
            ListeningHistoryEntry(
                authors: ["Author\(i)"],
                subjects: ["Subject\(i)"],
                listenedSeconds: 300
            )
        }
        let allEntries = [finished1, finished2, mostlyFinished] + barelyTouched

        let profile = RecommendationPipeline.buildProfile(
            history: allEntries,
            onboardingSelectionIDs: ["great-books"]
        )

        let top3 = profile.topCreators.prefix(3)
        XCTAssertTrue(top3.contains("homer"))
        XCTAssertTrue(top3.contains("plato"))
        XCTAssertTrue(top3.contains("sophocles"))
    }

    func testLongTimeListenerRecommendationsExcludeListened() {
        let finished1 = ListeningHistoryEntry(
            authors: ["Homer"],
            subjects: ["Epic Poetry"],
            listenedSeconds: 28800
        )
        let matched = candidate("match", "The Odyssey", "Homer", subjects: ["Epic Poetry"])
        let recs = RecommendationPipeline.recommendations(
            history: [finished1],
            onboardingSelectionIDs: [],
            candidates: [matched, candidate("other", "Other", "Someone Else", subjects: ["Cooking"])]
        )
        XCTAssertFalse(recs.map(\.identifier) == HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
    }

    // MARK: - Upgrade/backfill shape (author-only terms)

    func testBackfillShapeAuthorOnlyProfileNonEmpty() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            languages: [],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.creatorTerms.isEmpty)
        XCTAssertTrue(profile.subjectTerms.isEmpty)
    }

    // MARK: - Favorites

    func testUnlistenedFavoriteContributesBoost() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Fiction"],
            listenedSeconds: 0,
            isFavorite: true
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let authorTerm = profile.creatorTerms.first { $0.term == "jane austen" }
        XCTAssertNotNil(authorTerm)
        if let authorTerm {
            XCTAssertEqual(authorTerm.weight, RecommendationConstants.favoriteBoost, accuracy: 0.001)
        }
    }

    // MARK: - Junk resistance

    func testStopListSubjectsAreDamped() {
        let entry = ListeningHistoryEntry(
            subjects: ["music", "thriller"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let music = profile.subjectTerms.first { $0.term == "music" }
        let thriller = profile.subjectTerms.first { $0.term == "thriller" }
        if let music, let thriller {
            XCTAssertLessThan(music.weight, thriller.weight * 0.1, "stop-list should be ×0.05")
        }
    }

    func testUnknownAndVariousAuthorsAreDropped() {
        let entry = ListeningHistoryEntry(
            authors: ["Unknown", "Various", "Jane Austen"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        XCTAssertFalse(profile.creatorTerms.contains { $0.term == "unknown" })
        XCTAssertFalse(profile.creatorTerms.contains { $0.term == "various" })
        XCTAssertTrue(profile.creatorTerms.contains { $0.term == "jane austen" })
    }

    func testCollectionLikeSubjectsAreDropped() {
        let entry = ListeningHistoryEntry(
            subjects: ["lv-mystery-crime", "great-books", "Detective Fiction"],
            listenedSeconds: 3600
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        XCTAssertFalse(profile.subjectTerms.contains { $0.term == "lv-mystery-crime" })
        XCTAssertFalse(profile.subjectTerms.contains { $0.term == "great-books" })
        XCTAssertTrue(profile.subjectTerms.contains { $0.term == "detective fiction" })
    }

    // MARK: - Determinism

    func testPipelineIsDeterministic() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Romance", "Fiction"],
            listenedSeconds: 7200
        )
        let first = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: ["great-books"],
            candidates: [candidate("a", "A", "Jane Austen", subjects: ["Romance"]),
                         candidate("b", "B", "Someone", subjects: ["Fiction"])]
        )
        let second = RecommendationPipeline.recommendations(
            history: [entry],
            onboardingSelectionIDs: ["great-books"],
            candidates: [candidate("a", "A", "Jane Austen", subjects: ["Romance"]),
                         candidate("b", "B", "Someone", subjects: ["Fiction"])]
        )
        XCTAssertEqual(first.map(\.identifier), second.map(\.identifier))
    }

    // MARK: - Subject semicolon splitting

    func testTermWeightsSplitsSemicolonSubjects() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let weights = RecommendationPipeline.termWeights(history: [entry])
        let subjectWeights = weights.filter { $0.axis == "subject" }
        let subjectTerms = Set(subjectWeights.map(\.term))
        XCTAssertTrue(subjectTerms.contains("greek drama"))
        XCTAssertTrue(subjectTerms.contains("aristophanes"))
        XCTAssertTrue(subjectTerms.contains("greek comedy"))
        XCTAssertFalse(subjectTerms.contains { $0.contains(";") })
        XCTAssertFalse(subjectTerms.contains("librivox"))
        XCTAssertFalse(subjectTerms.contains("audiobooks"))
    }

    func testExtractTokensSplitsSemicolonSubjects() {
        let result = candidate(
            "test",
            "Test",
            "Author One",
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"]
        )
        let tokens = Set(RecommendationPipeline.extractTokens(result))
        XCTAssertTrue(tokens.contains("greek drama"))
        XCTAssertTrue(tokens.contains("aristophanes"))
        XCTAssertTrue(tokens.contains("greek comedy"))
        XCTAssertFalse(tokens.contains("librivox"), "stop-listed generic terms are dropped")
        XCTAssertFalse(tokens.contains("audiobooks"), "stop-listed generic terms are dropped")
        XCTAssertFalse(tokens.contains(";"))
    }

    func testScoreCandidatesMatchesSplitSubjects() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])

        let cand = candidate(
            "match",
            "The Frogs",
            "Aristophanes",
            subjects: ["greek drama", "comedy"]
        )
        let scored = RecommendationPipeline.scoreCandidates([cand], profile: profile)
        XCTAssertEqual(scored.count, 1)
        XCTAssertGreaterThan(scored[0].score, 0, "split subject profile should match individual subject tokens from search")
    }

    // MARK: - Query builder

    func testGeneratedSubjectQueriesUseSingleTerms() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: ["librivox; audiobooks;greek drama; aristophanes; greek comedy"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        for query in queries {
            if query.iaQuery.contains("subject:") {
                let subjectClauses = query.iaQuery.components(separatedBy: "subject:\"")
                for clause in subjectClauses.dropFirst() {
                    let endQuote = clause.components(separatedBy: "\"")
                    if let term = endQuote.first {
                        XCTAssertFalse(term.contains(";"), "generated query must not contain semicolon inside subject clause: '\(term)' in \(query.iaQuery)")
                    }
                }
            }
        }
    }

    func testExploitRowsFloor() {
        let entries: [ListeningHistoryEntry] = (0..<10).map { i in
            ListeningHistoryEntry(
                authors: ["Author\(i)"],
                subjects: [],
                listenedSeconds: 7200
            )
        }
        let profile = RecommendationPipeline.buildProfile(history: entries)
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        for query in queries where query.noveltyClass == .exploit {
            XCTAssertGreaterThanOrEqual(query.requestedCount, 4, "exploit query requestedCount must be at least 4")
        }
    }

    // MARK: - Narrator axis

    func testNarratorsAppearInProfileBucket() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.narratorTerms.isEmpty, "narrator should appear in profile")
        XCTAssertEqual(profile.narratorTerms.first?.term, "karen savage")
    }

    func testNarratorTermsFlowIntoAllTerms() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let allTerms = profile.allTerms()
        let narratorInAll = allTerms.filter { $0.axis == "narrator" }
        XCTAssertFalse(narratorInAll.isEmpty, "narrator terms should appear in allTerms()")
        XCTAssertTrue(narratorInAll.contains { $0.term == "karen savage" })
    }

    func testTopNarratorsReturnsWeightedNarrators() {
        let entries: [ListeningHistoryEntry] = [
            ListeningHistoryEntry(narrators: ["Karen Savage"], listenedSeconds: 7200),
            ListeningHistoryEntry(narrators: ["Elizabeth Klett"], listenedSeconds: 3600),
            ListeningHistoryEntry(narrators: ["Karen Savage"], listenedSeconds: 7200)
        ]
        let profile = RecommendationPipeline.buildProfile(history: entries)
        XCTAssertFalse(profile.narratorTerms.isEmpty)
        let savage = profile.narratorTerms.first { $0.term == "karen savage" }
        let klett = profile.narratorTerms.first { $0.term == "elizabeth klett" }
        if let savage, let klett {
            XCTAssertGreaterThan(savage.weight, klett.weight, "Karen Savage appears twice and should have higher weight")
        }
    }

    func testUnknownNarratorDroppedFromProfile() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: [],
            narrators: ["Unknown", "Various", "Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let narrators = profile.narratorTerms.map(\.term)
        XCTAssertFalse(narrators.contains("unknown"))
        XCTAssertFalse(narrators.contains("various"))
        XCTAssertTrue(narrators.contains("karen savage"))
    }

    func testExtractTokensIncludesNarrators() {
        let result = candidate(
            "test",
            "Test Title",
            "Author One",
            description: "Read by Karen Savage",
            subjects: ["Fiction"]
        )
        let tokens = Set(RecommendationPipeline.extractTokens(result))
        XCTAssertTrue(tokens.contains("karen savage"), "narrator should be extracted from description")
    }

    func testNarratorExploitQueryGenerated() {
        let entry = ListeningHistoryEntry(
            authors: [],
            subjects: [],
            narrators: ["Karen Savage"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: "2026-01-01",
            languageClause: ""
        )
        let hasNarratorQuery = queries.contains { $0.iaQuery.contains("description:\"karen savage\"") }
        XCTAssertTrue(hasNarratorQuery, "exploit query should include narrator-based description search")
    }

    // MARK: - Solo narration boost

    func testSoloNarrationGetsDoubleScore() {
        let entry = ListeningHistoryEntry(
            authors: ["Jane Austen"],
            subjects: ["Fiction"],
            listenedSeconds: 7200
        )
        let profile = RecommendationPipeline.buildProfile(history: [entry])

        let soloResult = candidate(
            "solo1",
            "Pride and Prejudice",
            "Jane Austen",
            description: "Read by Karen Savage",
            subjects: ["Fiction"]
        )
        let collabResult = candidate(
            "collab1",
            "Pride and Prejudice (Dramatic)",
            "Jane Austen",
            description: "Read by Various Readers",
            subjects: ["Fiction"]
        )

        let scored = RecommendationPipeline.scoreCandidates(
            [soloResult, collabResult],
            profile: profile
        )

        XCTAssertEqual(scored.count, 2)

        let soloScore = scored.first { $0.result.identifier == "solo1" }?.score ?? 0
        let collabScore = scored.first { $0.result.identifier == "collab1" }?.score ?? 0

        XCTAssertGreaterThan(soloScore, collabScore,
                         "solo narration should score higher than collaborative with same creator match")
    }

    func testSoloBoostConstantIsDefined() {
        XCTAssertEqual(RecommendationConstants.soloNarrationBoost, 2.0, accuracy: 0.001,
                       "solo narration boost must be 2.0")
        XCTAssertGreaterThan(RecommendationConstants.soloNarrationBoost, 1.0,
                             "solo boost must be greater than 1.0 to give advantage")
    }

    // MARK: - Helpers

    private func candidate(
        _ identifier: String,
        _ title: String,
        _ creator: String,
        description: String? = nil,
        downloads: Int? = nil,
        subjects: [String] = [],
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: description,
            collections: collections,
            downloads: downloads,
            date: nil,
            languages: ["english"],
            subjects: subjects
        )
    }
}
