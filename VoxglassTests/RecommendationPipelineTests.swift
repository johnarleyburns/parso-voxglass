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
        XCTAssertEqual(recs.map(\.identifier), HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
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
            onboardingSelectionIDs: ["ancient-greece"]
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

    // MARK: - Helpers

    private func candidate(
        _ identifier: String,
        _ title: String,
        _ creator: String,
        downloads: Int? = nil,
        subjects: [String] = [],
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: nil,
            collections: collections,
            downloads: downloads,
            date: nil,
            languages: ["english"],
            subjects: subjects
        )
    }
}
