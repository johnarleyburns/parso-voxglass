import XCTest
@testable import VoxglassCore

final class TasteProfileStoreTests: XCTestCase {

    func testDecayUpdateMatchesExponentialFormula() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-decay")
        let store = TasteProfileStore(database: database)

        let tau = RecommendationConstants.tau
        let previousWeight = 2.0
        let dt = tau // exactly one time constant ago
        let past = Date().timeIntervalSince1970 - dt

        try await database.prepare()
        try await database.execute(
            "INSERT INTO taste_profile_terms (axis, term, weight, last_ts) VALUES (?, ?, ?, ?)",
            [.string("author"), .string("jane austen"), .double(previousWeight), .double(past)]
        )

        await store.upsertTerm(axis: "author", term: "Jane Austen", increment: 1.0)

        let rows = try await database.query(
            "SELECT weight FROM taste_profile_terms WHERE axis = ? AND term = ?",
            [.string("author"), .string("jane austen")]
        )
        let weight = try XCTUnwrap(rows.first?.double("weight"))
        let expected = previousWeight * exp(-dt / tau) + 1.0
        XCTAssertEqual(weight, expected, accuracy: 0.001)
    }

    func testFreshUpsertUsesIncrementDirectly() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-fresh-upsert")
        let store = TasteProfileStore(database: database)

        await store.upsertTerm(axis: "subject", term: "gothic fiction", increment: 1.75)

        let rows = try await database.query(
            "SELECT weight FROM taste_profile_terms WHERE axis = ? AND term = ?",
            [.string("subject"), .string("gothic fiction")]
        )
        let weight = try XCTUnwrap(rows.first?.double("weight"))
        XCTAssertEqual(weight, 1.75, accuracy: 0.001)
    }

    func testSubjectDampingDownweightsBroadAndStopListTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-damping")
        let store = TasteProfileStore(database: database)

        await store.upsertTerm(axis: "author", term: "Mary Shelley", increment: 4.0)
        let subjects = ["horror", "gothic fiction", "science fiction", "romance"]
        for subject in subjects {
            await store.upsertTerm(axis: "subject", term: subject, increment: 4.0)
        }
        // Stop-list term goes straight to the table (seedSubject would filter it),
        // mimicking a legacy row; fetchProfile must crush it, not drop the row set.
        await store.upsertTerm(axis: "subject", term: "music", increment: 4.0)

        let profile = await store.fetchProfile()

        let author = try XCTUnwrap(profile.creatorTerms.first { $0.term == "mary shelley" })
        XCTAssertEqual(author.weight, 4.0, accuracy: 0.01, "author weights stay undamped")

        let distinctSubjects = Double(subjects.count + 1) // + "music"
        let divisor = 1.0 + log(distinctSubjects + 1.0)
        let horror = try XCTUnwrap(profile.subjectTerms.first { $0.term == "horror" })
        XCTAssertEqual(horror.weight, 4.0 / divisor, accuracy: 0.01)
        XCTAssertLessThan(horror.weight, author.weight)

        let stopListed = try XCTUnwrap(profile.subjectTerms.first { $0.term == "music" })
        XCTAssertEqual(stopListed.weight, 4.0 * 0.05, accuracy: 0.01)
        XCTAssertLessThan(stopListed.weight, horror.weight)
    }

    func testSeedSubjectFiltersStopListTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-stoplist-seed")
        let store = TasteProfileStore(database: database)

        await store.seedSubject("librivox")
        await store.seedSubject("  ")
        await store.seedSubject("detective fiction")

        let rows = try await database.query(
            "SELECT term FROM taste_profile_terms WHERE axis = 'subject'", []
        )
        XCTAssertEqual(rows.compactMap { $0.string("term") }, ["detective fiction"])
    }

    func testSurfacedRingRespectsCap() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-surfaced-cap")
        let store = TasteProfileStore(database: database)

        let cap = RecommendationConstants.recoSurfacedCap
        // pushSurfaced ingests at most 50 identifiers per call, so feed batches.
        var pushed = 0
        while pushed < cap + 100 {
            let batch = (pushed..<(pushed + 50)).map { "item-\($0)" }
            await store.pushSurfaced(batch)
            pushed += 50
        }

        let rows = try await database.query("SELECT COUNT(*) AS n FROM reco_surfaced", [])
        let count = try XCTUnwrap(rows.first?.int("n"))
        XCTAssertEqual(Int(count), cap)

        let surfaced = await store.fetchSurfacedIdentifiers()
        XCTAssertEqual(surfaced.count, cap)
    }

    func testHistoryRebuildIncludesAuthorsSubjectsAndLanguages() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-history-axes")
        let store = TasteProfileStore(database: database)
        try await seedHistoryBook(
            in: database,
            title: "The Clouds",
            author: "Aristophanes",
            subject: "Drama",
            language: "eng",
            listenedSeconds: 7200
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)

        let profile = await store.fetchProfile()
        XCTAssertTrue(profile.creatorTerms.contains { $0.term == "aristophanes" })
        XCTAssertTrue(profile.subjectTerms.contains { $0.term == "drama" })
        XCTAssertTrue(profile.languageTerms.contains { $0.term == "eng" })
    }

    func testHistoryRebuildUsesPlaybackPositionWhenNoListeningEventsExist() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-history-position-only")
        let store = TasteProfileStore(database: database)
        try await seedHistoryBook(
            in: database,
            title: "Position Only",
            author: "Position Author",
            subject: "Adventure",
            language: "eng",
            listenedSeconds: 0,
            playbackPositionSeconds: 5400,
            playbackDurationSeconds: 7200
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)

        let weight = try await rawWeight(in: database, axis: "author", term: "position author")
        XCTAssertEqual(weight, 1.5, accuracy: 0.001)
        let profile = await store.fetchProfile()
        XCTAssertTrue(profile.creatorTerms.contains { $0.term == "position author" })
        XCTAssertTrue(profile.subjectTerms.contains { $0.term == "adventure" })
        XCTAssertTrue(profile.languageTerms.contains { $0.term == "eng" })
    }

    func testOnboardingOnlyBrowsePickProfileIsNotEmpty() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-onboarding-browse-pick")
        let store = TasteProfileStore(database: database)

        await store.rebuildFromListeningHistory(
            version: TasteProfileStore.listeningHistoryRebuildVersion,
            selectedCollectionIDs: ["lv-mystery-crime"]
        )

        let hasProfile = await store.hasProfile()
        XCTAssertTrue(hasProfile)
        let profile = await store.fetchProfile()
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.subjectTerms.isEmpty)
    }

    func testFavoriteBookContributesProfileWeight() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-favorite-weight")
        let store = TasteProfileStore(database: database)
        try await seedHistoryBook(
            in: database,
            title: "Emma",
            author: "Jane Austen",
            subject: "Fiction",
            language: "eng",
            listenedSeconds: 0,
            isFavorite: true
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)

        let weight = try await rawWeight(in: database, axis: "author", term: "jane austen")
        XCTAssertEqual(weight, RecommendationConstants.favoriteBoost, accuracy: 0.001)
    }

    func testHistoryRebuildIsIdempotent() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-history-idempotent")
        let store = TasteProfileStore(database: database)
        try await seedHistoryBook(
            in: database,
            title: "The Clouds",
            author: "Aristophanes",
            subject: "Drama",
            language: "eng",
            listenedSeconds: 7200
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let first = try await rawWeight(in: database, axis: "author", term: "aristophanes")
        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let second = try await rawWeight(in: database, axis: "author", term: "aristophanes")

        XCTAssertEqual(first, 2.0, accuracy: 0.001)
        XCTAssertEqual(second, first, accuracy: 0.001)
    }

    func testHistoryRebuildIgnoresOldV1BackfillMarker() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-history-old-marker")
        let store = TasteProfileStore(database: database)
        let oldMarker = "voxglass.tasteHistoryBackfilledV1"
        UserDefaults.standard.set(true, forKey: oldMarker)
        defer { UserDefaults.standard.removeObject(forKey: oldMarker) }
        try await seedHistoryBook(
            in: database,
            title: "Hamlet",
            author: "William Shakespeare",
            subject: "Drama",
            language: "eng",
            listenedSeconds: 3600
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)

        let weight = try await rawWeight(in: database, axis: "author", term: "william shakespeare")
        XCTAssertEqual(weight, 1.0, accuracy: 0.001)
    }

    func testHistoryIncrementKeepsFloorAndCap() {
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 60), RecommendationConstants.minListenIncrement, "floor at minListenIncrement")
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 2 * 3600), 2.0, accuracy: 0.001)
        XCTAssertEqual(RecommendationPipeline.historyIncrement(forSeconds: 100 * 3600), 12.0, "cap at 12")
    }

    func testOnboardingAuthorSeedWeightStaysBelowMinListenIncrement() {
        XCTAssertLessThan(RecommendationConstants.onboardingAuthorSeedWeight, RecommendationConstants.minListenIncrement)
    }

    func testRebuildSeedsCuratedOnboardingPicksAsAuthors() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-curated-onboarding")
        let store = TasteProfileStore(database: database)

        await store.rebuildFromListeningHistory(
            version: TasteProfileStore.listeningHistoryRebuildVersion,
            selectedCollectionIDs: ["great-books"]
        )

        let rows = try await database.query(
            "SELECT axis, term FROM taste_profile_terms WHERE axis = 'author'", []
        )
        let authors = rows.compactMap { $0.string("term") }
        XCTAssertFalse(authors.isEmpty, "curated onboarding should seed author terms")
        for author in authors {
            let weight = try await rawWeight(in: database, axis: "author", term: author)
            XCTAssertEqual(weight, RecommendationConstants.onboardingAuthorSeedWeight, accuracy: 0.001)
        }
    }

    @discardableResult
    private func seedHistoryBook(
        in database: AppDatabase,
        title: String,
        author: String,
        subject: String,
        language: String,
        listenedSeconds: Double,
        isFavorite: Bool = false,
        playbackPositionSeconds: Double? = nil,
        playbackDurationSeconds: Double? = nil,
        playbackIsFinished: Bool = false
    ) async throws -> UUID {
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
            .string("https://archive.org/details/\(bookID.uuidString)"),
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string(ModelMapping.authorsJSON([author])),
            .null,
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(isFavorite)
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
            .null,
            .null
        ])
        for (axis, term) in [("author", author), ("subject", subject), ("language", language)] {
            try await database.execute(
                "INSERT INTO book_taste (book_id, axis, term) VALUES (?, ?, ?)",
                [.string(bookID.uuidString), .string(axis), .string(term.lowercased())]
            )
        }
        if listenedSeconds > 0 {
            try await database.execute("""
            INSERT INTO listening_events (id, book_id, seconds, occurred_at)
            VALUES (?, ?, ?, ?)
            """, [
                .string(UUID().uuidString),
                .string(bookID.uuidString),
                .double(listenedSeconds),
                .double(now)
            ])
        }
        if let playbackPositionSeconds {
            try await SQLitePositionStore(database: database).save(PlaybackPosition(
                bookID: bookID,
                chapterID: chapterID,
                position: playbackPositionSeconds,
                duration: playbackDurationSeconds,
                updatedAt: Date(timeIntervalSince1970: now),
                isFinished: playbackIsFinished
            ))
        }
        return bookID
    }

    private func rawWeight(in database: AppDatabase, axis: String, term: String) async throws -> Double {
        let rows = try await database.query(
            "SELECT weight FROM taste_profile_terms WHERE axis = ? AND term = ?",
            [.string(axis), .string(term)]
        )
        return try XCTUnwrap(rows.first?.double("weight"))
    }
}
