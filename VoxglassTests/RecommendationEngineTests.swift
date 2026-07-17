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
        let tokens = Set(RecommendationPipeline.extractTokens(result))
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

        let scored = RecommendationPipeline.scoreCandidates([popularOnly, subjectMatch], profile: profile)

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
        let picked = RecommendationPipeline.greedyMMR(scored, k: 2, lambda: RecommendationConstants.lambdaMMR)

        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[0].identifier, "frankenstein_v1")
        XCTAssertEqual(picked[1].identifier, "emma_librivox",
                       "MMR must prefer the diverse candidate over the near-duplicate")
    }

    func testJaccardSimilarityIsSubjectAware() {
        let a = candidate(identifier: "a", title: "A", creator: "Author One", subjects: ["Horror"])
        let b = candidate(identifier: "b", title: "B", creator: "Author Two", subjects: ["Horror"])
        XCTAssertGreaterThan(RecommendationPipeline.jaccardSimilarity(a, b), 0)
    }

    // MARK: - Listened exclusions

    @MainActor
    func testOnboardingOnlyProfileFetchesTunedRecommendations() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-onboarding-tuned")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.rebuildFromListeningHistory(
            version: TasteProfileStore.listeningHistoryRebuildVersion,
            selectedCollectionIDs: ["lv-mystery-crime"]
        )
        await libraryStore.refresh()

        let personalized = candidate(identifier: "personalized", title: "Personalized Mystery", creator: "Someone", subjects: ["Mystery"])
        let client = FakeArchiveClient(responses: [[personalized]])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(
            selectedCollectionIDs: ["lv-mystery-crime"],
            selectedLanguages: ["eng"]
        )

        let advancedQueryCount = await client.advancedQueryCount
        XCTAssertGreaterThan(advancedQueryCount, 0, "onboarding-only profile should trigger engine queries")
        let queries = await client.advancedQueries
        let hasSubjectQuery = queries.contains { $0.contains("subject:") }
        XCTAssertTrue(hasSubjectQuery)
        XCTAssertEqual(recs.map(\.identifier), ["personalized"])
    }

    @MainActor
    func testEngineTunesAfterSingleMeaningfulListen() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-single-meaningful-listen")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        try await seedListenedBook(
            in: database,
            title: "The Clouds",
            author: "Aristophanes",
            iaIdentifier: "clouds_librivox"
        )
        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        await libraryStore.refresh()

        let result = candidate(identifier: "clouds_new", title: "The Birds", creator: "Aristophanes", subjects: ["Drama"])
        let client = FakeArchiveClient(responses: [[result], []])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let queries = await client.advancedQueries

        XCTAssertTrue(queries.contains { $0.localizedCaseInsensitiveContains("creator:\"aristophanes\"") })
        XCTAssertEqual(recs.map(\.identifier), [result.identifier])
    }

    @MainActor
    func testPositionOnlyJumpBackInHistoryPersonalizesRecommendations() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-position-only-jump-back")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        var seededAuthorTerms: Set<String> = []

        for index in 0..<12 {
            let author = "Position Archive Author \(index % 4)"
            seededAuthorTerms.insert(author.lowercased())
            try await seedPositionOnlyBook(
                in: database,
                title: "Position History \(index)",
                author: author,
                subject: "Position History Subject \(index % 3)",
                iaIdentifier: "position_history_\(index)",
                position: 1800 + Double(index * 30),
                duration: 7200,
                updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(index))
            )
        }

        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let profile = await profileStore.fetchProfile()
        await libraryStore.refresh()

        let topAuthor = try XCTUnwrap(profile.topCreators.first)
        let listenedAgain = candidate(
            identifier: "position_history_0",
            title: "Position History 0",
            creator: "Position Archive Author 0",
            subjects: ["Position History Subject 0"]
        )
        let personalized = candidate(
            identifier: "fresh_position_history_pick",
            title: "A Fresh Position History",
            creator: topAuthor,
            subjects: ["Position History Subject 0"]
        )
        let client = FakeArchiveClient(responses: [[listenedAgain, personalized]])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let queries = await client.advancedQueries
        let bundledPopularIDs = Set(HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))

        XCTAssertFalse(profile.isEmpty)
        XCTAssertEqual(libraryStore.recentlyPlayed.count, 12)
        XCTAssertTrue(Set(profile.topCreators).isSubset(of: seededAuthorTerms))
        XCTAssertTrue(queries.contains { $0.localizedCaseInsensitiveContains("creator:\"\(topAuthor)\"") })
        XCTAssertEqual(recs.map(\.identifier), [personalized.identifier])
        XCTAssertTrue(Set(recs.map(\.identifier)).isDisjoint(with: bundledPopularIDs))
    }

    @MainActor
    func testGeneratedTTSAndAudioBooksPoetryCandidatesAreExcluded() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-generated-tts-filter")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let generated = candidate(
            identifier: "synapseml_gutenberg_the_eleven_comedies_volume_1_by_aristoph",
            title: "The Eleven Comedies",
            creator: "Microsoft TTS",
            subjects: ["Drama"],
            collections: ["audio_bookspoetry"]
        )
        let fresh = candidate(
            identifier: "fresh_clouds_librivox",
            title: "The Clouds",
            creator: "Aristophanes",
            subjects: ["Drama"],
            collections: ["librivoxaudio"]
        )
        let client = FakeArchiveClient(responses: [[generated, fresh], []])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let queries = await client.advancedQueries

        XCTAssertFalse(recs.contains { $0.identifier == generated.identifier })
        XCTAssertTrue(recs.contains { $0.identifier == fresh.identifier })
        XCTAssertTrue(queries.allSatisfy { $0.contains("collection:librivoxaudio") })
        XCTAssertTrue(queries.allSatisfy { !$0.contains("audio_bookspoetry") })
    }

    @MainActor
    func testListenedIAIdentifierCandidateIsExcluded() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-listened-ia")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        try await seedListenedBook(
            in: database,
            title: "Local Recording",
            author: "Someone Else",
            iaIdentifier: "clouds_librivox"
        )
        await profileStore.upsertTerm(axis: "subject", term: "drama", increment: 5)
        await libraryStore.refresh()

        let fresh = candidate(identifier: "fresh_drama", title: "A Fresh Drama", creator: "Fresh Author", subjects: ["Drama"])
        let client = FakeArchiveClient(responses: [
            [
                candidate(identifier: "clouds_librivox", title: "Different Metadata", creator: "Different Author", subjects: ["Drama"]),
                fresh
            ],
            []
        ])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])

        XCTAssertFalse(recs.contains { $0.identifier == "clouds_librivox" })
        XCTAssertTrue(recs.contains(fresh))
    }

    @MainActor
    func testListenedWorkKeyCandidateIsExcludedAcrossDifferentIAIdentifier() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-listened-workkey")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        try await seedListenedBook(
            in: database,
            title: "Frankenstein (Version 2)",
            author: "Mary Shelley",
            iaIdentifier: "old_frankenstein"
        )
        await profileStore.upsertTerm(axis: "author", term: "Mary Shelley", increment: 5)
        await libraryStore.refresh()

        let fresh = candidate(identifier: "fresh_shelley", title: "The Last Man", creator: "Mary Shelley", subjects: ["Gothic Fiction"])
        let client = FakeArchiveClient(responses: [
            [
                candidate(identifier: "new_frankenstein_upload", title: "Frankenstein", creator: "Mary Shelley", subjects: ["Gothic Fiction"]),
                fresh
            ],
            []
        ])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])

        XCTAssertFalse(recs.contains { $0.identifier == "new_frankenstein_upload" })
        XCTAssertTrue(recs.contains(fresh))
    }

    @MainActor
    func testJumpBackInAndRecommendationsDoNotShareAWork() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-jump-back-overlap")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        let listened = try await seedListenedBook(
            in: database,
            title: "The Clouds",
            author: "Aristophanes",
            iaIdentifier: "clouds_old"
        )
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let client = FakeArchiveClient(responses: [
            [
                candidate(identifier: "clouds_new", title: "The Clouds (Dramatic Reading)", creator: "Aristophanes", subjects: ["Drama"]),
                candidate(identifier: "birds_fresh", title: "The Birds", creator: "Aristophanes", subjects: ["Drama"])
            ],
            []
        ])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let jumpBackWorkKeys = Set(libraryStore.recentlyPlayed.map {
            WorkKey.normalized(author: $0.book.authorLine, title: $0.book.title)
        })
        let recommendationWorkKeys = Set(recs.map {
            WorkKey.normalized(author: $0.authorLine, title: $0.title)
        })

        XCTAssertEqual(libraryStore.recentlyPlayed.map(\.book.id), [listened.bookID])
        XCTAssertTrue(jumpBackWorkKeys.isDisjoint(with: recommendationWorkKeys))
        XCTAssertTrue(recs.contains { $0.identifier == "birds_fresh" })
    }

    @MainActor
    func testProfileFallbackUsesProfileCandidatesBeforeBundledPopularSeeds() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-profile-fallback")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let profileFallback = candidate(
            identifier: "profile_fallback",
            title: "The Acharnians",
            creator: "Aristophanes",
            subjects: ["Drama"]
        )
        let client = FakeArchiveClient(responses: [
            [],
            [profileFallback]
        ])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let bundledPopularIDs = Set(HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
        let advancedQueryCount = await client.advancedQueryCount

        XCTAssertEqual(recs.map(\.identifier), ["profile_fallback"])
        XCTAssertTrue(Set(recs.map(\.identifier)).isDisjoint(with: bundledPopularIDs))
        XCTAssertEqual(advancedQueryCount, 2)
    }

    @MainActor
    func testEngineFallsBackToBundledSeedsWhenGeneratedQueriesAreEmpty() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-empty-generated-queries")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "language", term: "english", increment: 5)
        await libraryStore.refresh()

        let client = FakeArchiveClient(responses: [])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        let advancedQueryCount = await client.advancedQueryCount

        XCTAssertEqual(recs.map(\.identifier), HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
        XCTAssertEqual(advancedQueryCount, 0)
    }

    @MainActor
    func testEngineFallsBackToBundledSeedsWhenNetworkCandidatesAreEmpty() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "reco-empty-network-candidates")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let client = FakeArchiveClient(responses: [[], []])
        let engine = RecommendationEngine(client: client, profileStore: profileStore, libraryStore: libraryStore)

        let recs = await engine.fetchRecommendations(selectedCollectionIDs: [], selectedLanguages: ["eng"])

        XCTAssertEqual(recs.map(\.identifier), HomeRecommendationStore.bundledPopularSeeds.map(\.identifier))
    }

    @MainActor
    func testHomeRecommendationStorePreservesVisibleRecommendationsWhenRefreshReturnsEmpty() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "home-reco-preserve-empty-refresh")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)

        for seed in HomeRecommendationStore.bundledPopularSeeds {
            try await seedListenedBook(
                in: database,
                title: seed.title,
                author: seed.authorLine,
                iaIdentifier: seed.identifier
            )
        }
        await libraryStore.refresh()

        let store = HomeRecommendationStore(client: FakeArchiveClient(responses: [[], []]))
        let original = store.recommendations
        store.configure(profileStore: profileStore, libraryStore: libraryStore)
        store.markEngineReady()

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])

        XCTAssertEqual(store.recommendations, original)
    }

    @MainActor
    func testHomeRecommendationStorePreservesPersonalizedShelfWhenRefreshFallsBackToBundledPopular() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "home-reco-preserve-personalized")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let personalized = candidate(
            identifier: "aristophanes_personalized",
            title: "The Frogs",
            creator: "Aristophanes",
            downloads: 400,
            subjects: ["Drama"]
        )
        let store = HomeRecommendationStore(client: FakeArchiveClient(responses: [
            [personalized],
            [],
            [],
            []
        ]))
        store.configure(profileStore: profileStore, libraryStore: libraryStore)
        store.markEngineReady()

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        XCTAssertEqual(store.recommendations.map(\.identifier), ["aristophanes_personalized"])

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        XCTAssertEqual(store.recommendations.map(\.identifier), ["aristophanes_personalized"])
        XCTAssertNotEqual(
            store.recommendations.map(\.identifier),
            HomeRecommendationStore.bundledPopularSeeds.map(\.identifier)
        )
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

    @discardableResult
    private func seedListenedBook(
        in database: AppDatabase,
        title: String,
        author: String,
        iaIdentifier: String
    ) async throws -> (bookID: UUID, chapterID: UUID) {
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.librivox.rawValue),
            .string(title),
            .string("https://archive.org/details/\(iaIdentifier)"),
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string(ModelMapping.authorsJSON([author])),
            .null,
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(false),
            .string("ia:\(iaIdentifier)")
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter 1"),
            .string("Chapter 1"),
            .int(0),
            .double(120),
            .string("https://archive.org/download/\(iaIdentifier)/chapter.mp3"),
            .null
        ])
        try await SQLitePositionStore(database: database).save(PlaybackPosition(
            bookID: bookID,
            chapterID: chapterID,
            position: 10,
            duration: 120
        ))
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'author', ?)",
            [.string(bookID.uuidString), .string(author.lowercased())]
        )
        try await database.execute("""
        INSERT INTO listening_events (id, book_id, seconds, occurred_at)
        VALUES (?, ?, ?, ?)
        """, [
            .string(UUID().uuidString),
            .string(bookID.uuidString),
            .double(60),
            .double(now)
        ])
        return (bookID, chapterID)
    }

    @discardableResult
    private func seedPositionOnlyBook(
        in database: AppDatabase,
        title: String,
        author: String,
        subject: String,
        iaIdentifier: String,
        position: Double,
        duration: Double,
        updatedAt: Date
    ) async throws -> (bookID: UUID, chapterID: UUID) {
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = updatedAt.timeIntervalSince1970
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.librivox.rawValue),
            .string(title),
            .string("https://archive.org/details/\(iaIdentifier)"),
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string(ModelMapping.authorsJSON([author])),
            .null,
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(false),
            .string("ia:\(iaIdentifier)")
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter 1"),
            .string("Chapter 1"),
            .int(0),
            .double(duration),
            .string("https://archive.org/download/\(iaIdentifier)/chapter.mp3"),
            .null
        ])
        try await SQLitePositionStore(database: database).save(PlaybackPosition(
            bookID: bookID,
            chapterID: chapterID,
            position: position,
            duration: duration,
            updatedAt: updatedAt
        ))
        for (axis, term) in [("author", author), ("subject", subject), ("language", "eng")] {
            try await database.execute(
                "INSERT INTO book_taste (book_id, axis, term) VALUES (?, ?, ?)",
                [.string(bookID.uuidString), .string(axis), .string(term.lowercased())]
            )
        }
        return (bookID, chapterID)
    }

    private final class FakeArchiveClient: InternetArchiveCatalogClient {
        private let state: State

        var advancedQueryCount: Int {
            get async { await state.advancedQueryCount }
        }

        var advancedQueries: [String] {
            get async { await state.advancedQueries }
        }

        init(responses: [[InternetArchiveSearchResult]]) {
            self.state = State(responses: responses)
        }

        func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
            []
        }

        func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
            []
        }

        func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
            let response = await state.nextResponse(for: query)
            return InternetArchivePage(results: response, numFound: response.count, page: page)
        }

        func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
            throw InternetArchiveError.itemNotFound(identifier)
        }

        private actor State {
            private let responses: [[InternetArchiveSearchResult]]
            private var queries: [String] = []

            var advancedQueryCount: Int { queries.count }
            var advancedQueries: [String] { queries }

            init(responses: [[InternetArchiveSearchResult]]) {
                self.responses = responses
            }

            func nextResponse(for query: String) -> [InternetArchiveSearchResult] {
                queries.append(query)
                let index = queries.count - 1
                return index < responses.count ? responses[index] : []
            }
        }
    }
}
