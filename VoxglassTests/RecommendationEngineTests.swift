import XCTest
@testable import VoxglassCore

final class RecommendationEngineTests: XCTestCase {

    // MARK: - Subjects through the search pipeline

    func testAdvancedSearchURLRequestsSubjectField() throws {
        let url = try XCTUnwrap(
            InternetArchiveClient.advancedSearchURL(query: "collection:librivoxaudio", rows: 10, page: 1)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fields = (components.queryItems ?? [])
            .filter { $0.name == "fl[]" }
            .compactMap(\.value)
        XCTAssertTrue(fields.contains("subject"))
        XCTAssertTrue(fields.contains("language"))
    }

    func testSearchDocumentDecodesSubjectAsStringOrArray() throws {
        let json = """
        {
          "response": {
            "numFound": 2,
            "docs": [
              {
                "identifier": "frankenstein_librivox",
                "title": "Frankenstein",
                "creator": "Mary Shelley",
                "subject": ["Horror", "Gothic Fiction"]
              },
              {
                "identifier": "dracula_librivox",
                "title": "Dracula",
                "creator": "Bram Stoker",
                "subject": "Horror"
              }
            ]
          }
        }
        """
        let response = try JSONDecoder().decode(
            InternetArchiveSearchResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.results[0].subjects, ["Horror", "Gothic Fiction"])
        XCTAssertEqual(response.results[1].subjects, ["Horror"])
    }

    func testSearchDocumentDefaultsToEmptySubjects() throws {
        let json = """
        {"response": {"docs": [{"identifier": "no_subject_item"}]}}
        """
        let response = try JSONDecoder().decode(
            InternetArchiveSearchResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.results[0].subjects, [])
    }

    // MARK: - Token extraction

    func testExtractTokensIncludesNormalizedSubjectsAndSkipsStopList() {
        let result = candidate(
            identifier: "frankenstein_librivox",
            title: "Frankenstein",
            creator: "Mary Shelley",
            subjects: [" Gothic Fiction ", "LibriVox", "", "Horror"]
        )
        let tokens = Set(RecommendationEngine.extractTokens(result))
        XCTAssertTrue(tokens.contains("mary shelley"))
        XCTAssertTrue(tokens.contains("gothic fiction"))
        XCTAssertTrue(tokens.contains("horror"))
        XCTAssertFalse(tokens.contains("librivox"), "subject stop-list terms are dropped")
        XCTAssertFalse(tokens.contains(""))
    }

    // MARK: - Scoring

    func testSharedProfileSubjectOutranksPopularityOnlyCandidate() {
        let profile = ProfileBucket(
            bucket: "audiobooks",
            creatorTerms: [],
            subjectTerms: [TasteTerm(axis: "subject", term: "gothic fiction", weight: 5.0)]
        )
        let subjectMatch = candidate(
            identifier: "match",
            title: "The Castle of Otranto",
            creator: "Horace Walpole",
            downloads: 50,
            subjects: ["Gothic Fiction"]
        )
        let popularOnly = candidate(
            identifier: "popular",
            title: "Random Popular Book",
            creator: "Someone Else",
            downloads: 5_000_000,
            subjects: ["Cooking"]
        )

        let scored = RecommendationEngine.scoreCandidates([popularOnly, subjectMatch], profile: profile)

        XCTAssertEqual(scored.first?.result.identifier, "match")
        let matchScore = scored.first { $0.result.identifier == "match" }?.score ?? 0
        let popScore = scored.first { $0.result.identifier == "popular" }?.score ?? 0
        XCTAssertGreaterThan(matchScore, popScore)
    }

    // MARK: - MMR diversification

    func testMMRDiversifiesNearDuplicateSameAuthorSubjectCandidates() {
        let dupeA = candidate(
            identifier: "frankenstein_v1",
            title: "Frankenstein",
            creator: "Mary Shelley",
            subjects: ["Horror", "Gothic Fiction"]
        )
        let dupeB = candidate(
            identifier: "frankenstein_v2",
            title: "Frankenstein (version 2)",
            creator: "Mary Shelley",
            subjects: ["Horror", "Gothic Fiction"]
        )
        let distinct = candidate(
            identifier: "emma_librivox",
            title: "Emma",
            creator: "Jane Austen",
            subjects: ["Romance"]
        )

        let scored: [(result: InternetArchiveSearchResult, score: Double)] = [
            (dupeA, 1.0),
            (dupeB, 0.95),
            (distinct, 0.6)
        ]
        let picked = RecommendationEngine.greedyMMR(scored, k: 2, lambda: RecommendationConstants.lambdaMMR)

        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[0].identifier, "frankenstein_v1")
        XCTAssertEqual(picked[1].identifier, "emma_librivox",
                       "MMR must prefer the diverse candidate over the near-duplicate")
    }

    func testJaccardSimilarityIsSubjectAware() {
        let a = candidate(identifier: "a", title: "A", creator: "Author One", subjects: ["Horror"])
        let b = candidate(identifier: "b", title: "B", creator: "Author Two", subjects: ["Horror"])
        XCTAssertGreaterThan(RecommendationEngine.jaccardSimilarity(a, b), 0)
    }

    // MARK: - WorkKey

    func testWorkKeyCollapsesReuploadsOfTheSameWork() {
        let base = WorkKey.normalized(author: "Mary Shelley", title: "Frankenstein")
        XCTAssertEqual(WorkKey.normalized(author: "Mary  Shelley", title: "Frankenstein (version 2)"), base)
        XCTAssertEqual(WorkKey.normalized(author: "mary shelley", title: "Frankenstein (Dramatic Reading)"), base)
        XCTAssertNotEqual(WorkKey.normalized(author: "Mary Shelley", title: "The Last Man"), base)
    }

    // MARK: - Helpers

    private func candidate(
        identifier: String,
        title: String,
        creator: String,
        downloads: Int? = nil,
        subjects: [String] = []
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: downloads,
            date: nil,
            languages: ["english"],
            subjects: subjects
        )
    }
}
