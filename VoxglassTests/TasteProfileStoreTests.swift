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

    func testHistoryIncrementKeepsFloorAndCap() {
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 60), 0.5, "floor at 0.5")
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 2 * 3600), 2.0, accuracy: 0.001)
        XCTAssertEqual(TasteProfileStore.historyIncrement(forSeconds: 100 * 3600), 12.0, "cap at 12")
    }
}
