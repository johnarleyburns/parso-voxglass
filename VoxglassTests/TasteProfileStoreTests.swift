import Testing
import Foundation
@testable import VoxglassCore

@Suite(.serialized) struct TasteProfileStoreTests {

    @Test func decayUpdateMatchesExponentialFormula() async throws {
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
        let weight = try #require(rows.first?.double("weight"))
        let expected = previousWeight * exp(-dt / tau) + 1.0
        #expect(abs((weight) - (expected)) <= 0.001)
    }

    @Test func freshUpsertUsesIncrementDirectly() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-fresh-upsert")
        let store = TasteProfileStore(database: database)

        await store.upsertTerm(axis: "subject", term: "gothic fiction", increment: 1.75)

        let rows = try await database.query(
            "SELECT weight FROM taste_profile_terms WHERE axis = ? AND term = ?",
            [.string("subject"), .string("gothic fiction")]
        )
        let weight = try #require(rows.first?.double("weight"))
        #expect(abs((weight) - (1.75)) <= 0.001)
    }

    @Test func subjectDampingDownweightsBroadAndStopListTerms() async throws {
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

        let author = try #require(profile.creatorTerms.first { $0.term == "mary shelley" })
        #expect(abs((author.weight) - (4.0)) <= 0.001)  // author weights stay undamped

        let distinctSubjects = Double(subjects.count + 1) // + "music"
        let divisor = 1.0 + log(distinctSubjects + 1.0)
        let horror = try #require(profile.subjectTerms.first { $0.term == "horror" })
        #expect(abs((horror.weight) - (4.0 / divisor)) <= 0.01)
        #expect(horror.weight < author.weight)

        let stopListed = try #require(profile.subjectTerms.first { $0.term == "music" })
        #expect(abs((stopListed.weight) - (4.0 * 0.05)) <= 0.01)
        #expect(stopListed.weight < horror.weight)
    }

    @Test func seedSubjectFiltersStopListTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-stoplist-seed")
        let store = TasteProfileStore(database: database)

        await store.seedSubject("librivox")
        await store.seedSubject("  ")
        await store.seedSubject("detective fiction")

        let rows = try await database.query(
            "SELECT term FROM taste_profile_terms WHERE axis = 'subject'", []
        )
        #expect(rows.compactMap { $0.string("term") } == ["detective fiction"])
    }

    @Test func surfacedRingRespectsCap() async throws {
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
        let count = try #require(rows.first?.int("n"))
        #expect(Int(count) == cap)

        let surfaced = await store.fetchSurfacedIdentifiers()
        #expect(surfaced.count == cap)
    }

    @Test func historyRebuildIncludesAuthorsSubjectsAndLanguages() async throws {
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
        #expect(profile.creatorTerms.contains { $0.term == "aristophanes" })
        #expect(profile.subjectTerms.contains { $0.term == "drama" })
        #expect(profile.languageTerms.contains { $0.term == "eng" })
    }

    @Test func historyRebuildUsesPlaybackPositionWhenNoListeningEventsExist() async throws {
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
        #expect(abs((weight) - (1.5)) <= 0.001)
        let profile = await store.fetchProfile()
        #expect(profile.creatorTerms.contains { $0.term == "position author" })
        #expect(profile.subjectTerms.contains { $0.term == "adventure" })
        #expect(profile.languageTerms.contains { $0.term == "eng" })
    }

    @Test func onboardingOnlyBrowsePickProfileIsNotEmpty() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-onboarding-browse-pick")
        let store = TasteProfileStore(database: database)

        await store.rebuildFromListeningHistory(
            version: TasteProfileStore.listeningHistoryRebuildVersion,
            selectedCollectionIDs: ["lv-mystery-crime"]
        )

        let hasProfile = await store.hasProfile()
        #expect(hasProfile)
        let profile = await store.fetchProfile()
        #expect(!(profile.isEmpty))
        #expect(!(profile.subjectTerms.isEmpty))
    }

    @Test func favoriteBookContributesProfileWeight() async throws {
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
        #expect(abs((weight) - (RecommendationConstants.favoriteBoost)) <= 0.001)
    }

    @Test func historyRebuildIsIdempotent() async throws {
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

        #expect(abs((first) - (2.0)) <= 0.001)
        #expect(abs((second) - (first)) <= 0.001)
    }

    @Test func historyRebuildIgnoresOldV1BackfillMarker() async throws {
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
        #expect(abs((weight) - (1.0)) <= 0.001)
    }

    @Test func historyIncrementKeepsFloorAndCap() {
        #expect(RecommendationPipeline.historyIncrement(forSeconds: 60) == RecommendationConstants.minListenIncrement)  // floor at minListenIncrement
        #expect(abs((RecommendationPipeline.historyIncrement(forSeconds: 2 * 3600)) - (2.0)) <= 0.001)
        #expect(RecommendationPipeline.historyIncrement(forSeconds: 100 * 3600) == 12.0)  // cap at 12
    }

    @Test func onboardingAuthorSeedWeightStaysBelowMinListenIncrement() {
        #expect(RecommendationConstants.onboardingAuthorSeedWeight < RecommendationConstants.minListenIncrement)
    }

    @Test func rebuildSeedsCuratedOnboardingPicksAsAuthors() async throws {
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
        #expect(!(authors.isEmpty))  // curated onboarding should seed author terms
        for author in authors {
            let weight = try await rawWeight(in: database, axis: "author", term: author)
            #expect(abs((weight) - (RecommendationConstants.onboardingAuthorSeedWeight)) <= 0.001)
        }
    }

    @Test func concurrentFetchDuringRebuildNeverSeesEmptyProfile() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-atomic-rebuild")
        let store = TasteProfileStore(database: database)
        try await seedHistoryBook(
            in: database,
            title: "The Frogs",
            author: "Aristophanes",
            subject: "Drama",
            language: "eng",
            listenedSeconds: 7200
        )

        await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let initial = await store.fetchProfile()
        #expect(!(initial.isEmpty))  // seeded history must produce a non-empty profile

        let rebuilds = Task {
            for _ in 0..<40 {
                await store.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
            }
        }
        var emptyReads = 0
        for _ in 0..<400 {
            let profile = await store.fetchProfile()
            if profile.isEmpty {
                emptyReads += 1
            }
        }
        await rebuilds.value

        #expect(emptyReads == 0)  // fetchProfile interleaved with a rebuild must never observe an empty (mid-transaction) profile
    }

    // MARK: - Surfaced ring TTL

    @Test func surfacedRingExpiresByTTL() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-surfaced-ttl")
        let store = TasteProfileStore(database: database)
        let now = Date().timeIntervalSince1970
        let ttl = RecommendationConstants.recoSurfacedTTL

        try await database.execute(
            "INSERT INTO reco_surfaced (identifier, ts) VALUES (?, ?)",
            [.string("old-item"), .double(now - ttl - 86400)]
        )
        try await database.execute(
            "INSERT INTO reco_surfaced (identifier, ts) VALUES (?, ?)",
            [.string("fresh-item"), .double(now)]
        )

        let surfaced = await store.fetchSurfacedIdentifiers()
        #expect(!(surfaced.contains("old-item")))  // expired surfaced item must be purged by TTL
        #expect(surfaced.contains("fresh-item"))  // fresh surfaced item must survive TTL check
    }

    // MARK: - Anonymous author filtering

    @Test func normalizedTermRejectsAnonymousAuthor() {
        #expect(RecommendationPipeline.normalizedTerm(axis: "author", term: "Jane Austen") != nil)
        #expect(RecommendationPipeline.normalizedTerm(axis: "author", term: "anonymous") == nil)
        #expect(RecommendationPipeline.normalizedTerm(axis: "author", term: "Anonymous") == nil)
    }

    @Test func seedAuthorRejectsAnonymous() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "taste-seed-anonymous")
        let store = TasteProfileStore(database: database)

        await store.seedAuthor("Jane Austen")
        await store.seedAuthor("anonymous")
        await store.seedAuthor("Anonymous")

        let rows = try await database.query(
            "SELECT term FROM taste_profile_terms WHERE axis = 'author'", []
        )
        let terms = rows.compactMap { $0.string("term") }
        #expect(terms == ["jane austen"])
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
        return try #require(rows.first?.double("weight"))
    }
}
