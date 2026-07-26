import Testing
import Foundation
@testable import VoxglassCore

@Suite struct TasteSignalCaptureTests {

    @Test func belowThresholdPeriodicSaveDoesNotUpsert() async throws {
        let harness = try await makeHarness(named: "signal-below-threshold")

        await harness.apply(position: 10, duration: 100, isFavorite: false, isFinished: false)

        let weight = try await harness.authorWeight()
        #expect(weight == nil)  // sub-20% listens must not touch the profile
        let state = try await harness.state()
        #expect(state == nil)  // sub-20% listens must not create signal state
    }

    @Test func invalidDurationIsIgnoredUnlessFinished() async throws {
        let harness = try await makeHarness(named: "signal-invalid-duration")

        await harness.apply(position: 500, duration: nil, isFavorite: false, isFinished: false)
        let weight = try await harness.authorWeight()
        #expect(weight == nil)

        await harness.apply(position: 500, duration: nil, isFavorite: false, isFinished: true)
        let finishedWeight = try await harness.authorWeight()
        #expect(abs((try #require(finishedWeight)) - (1.0)) <= 0.01)
    }

    @Test func crossingThresholdUpsertsOnceAndPeriodicRepeatsAreNoOps() async throws {
        let harness = try await makeHarness(named: "signal-threshold-once")

        await harness.apply(position: 30, duration: 100, isFavorite: false, isFinished: false)
        let firstValue = try await harness.authorWeight()
        let first = try #require(firstValue)
        #expect(abs((first) - (0.5)) <= 0.001)  // targetIncrement = max(0.5, 0.3)

        // Simulated 5-second periodic saves at the same completion: no growth.
        for _ in 0..<10 {
            await harness.apply(position: 30, duration: 100, isFavorite: false, isFinished: false)
        }
        let afterRepeatsValue = try await harness.authorWeight()
        let afterRepeats = try #require(afterRepeatsValue)
        #expect(abs((afterRepeats) - (first)) <= 0.001)  // repeated periodic saves must not change weights
    }

    @Test func progressAddsOnlyThePositiveDelta() async throws {
        let harness = try await makeHarness(named: "signal-progress-delta")

        await harness.apply(position: 30, duration: 100, isFavorite: false, isFinished: false)
        await harness.apply(position: 80, duration: 100, isFavorite: false, isFinished: false)

        let weightValue = try await harness.authorWeight()
        let weight = try #require(weightValue)
        #expect(abs((weight) - (0.8)) <= 0.001)  // 0.5 then +0.3 delta as completion rises

        let stateValue = try await harness.state()
        let state = try #require(stateValue)
        #expect(abs((state.maxCompletion) - (0.8)) <= 0.001)
        #expect(abs((state.appliedIncrement) - (0.8)) <= 0.001)
    }

    @Test func finishingAddsOnlyTheCompletionDelta() async throws {
        let harness = try await makeHarness(named: "signal-finish-delta")

        await harness.apply(position: 50, duration: 100, isFavorite: false, isFinished: false)
        await harness.apply(position: 100, duration: 100, isFavorite: false, isFinished: true)
        let weightValue = try await harness.authorWeight()
        let weight = try #require(weightValue)
        #expect(abs((weight) - (1.0)) <= 0.001)  // 0.5 first, then only the 0.5 finish delta

        // A second finished save (e.g. another chapter-end persist) is a no-op.
        await harness.apply(position: 100, duration: 100, isFavorite: false, isFinished: true)
        let repeatedValue = try await harness.authorWeight()
        let repeated = try #require(repeatedValue)
        #expect(abs((repeated) - (1.0)) <= 0.01)
    }

    @Test func favoritingAddsOnlyTheFavoriteDeltaOnce() async throws {
        let harness = try await makeHarness(named: "signal-favorite-delta")

        await harness.apply(position: 100, duration: 100, isFavorite: false, isFinished: true)
        let baseValue = try await harness.authorWeight()
        let base = try #require(baseValue)
        #expect(abs((base) - (1.0)) <= 0.01)

        await harness.apply(position: 100, duration: 100, isFavorite: true, isFinished: true)
        let favoritedValue = try await harness.authorWeight()
        let favorited = try #require(favoritedValue)
        #expect(abs((favorited) - (RecommendationConstants.favoriteBoost)) <= 0.001)  // target becomes 1.0 × favoriteBoost; only the delta is added

        await harness.apply(position: 100, duration: 100, isFavorite: true, isFinished: true)
        let repeatedValue = try await harness.authorWeight()
        let repeated = try #require(repeatedValue)
        #expect(abs((repeated) - (RecommendationConstants.favoriteBoost)) <= 0.001)  // the favorite delta is applied exactly once
    }

    // MARK: - Harness

    private struct SignalState {
        let maxCompletion: Double
        let appliedIncrement: Double
    }

    private struct Harness {
        let database: AppDatabase
        let store: TasteProfileStore
        let bookID: UUID
        let terms: [(axis: String, term: String)]

        func apply(position: TimeInterval, duration: TimeInterval?,
                   isFavorite: Bool, isFinished: Bool) async {
            await store.applySignal(
                PlaybackTasteSignal(
                    bookID: bookID,
                    isFavorite: isFavorite,
                    position: position,
                    duration: duration,
                    isFinished: isFinished
                ),
                terms: terms
            )
        }

        func authorWeight() async throws -> Double? {
            let rows = try await database.query(
                "SELECT weight FROM taste_profile_terms WHERE axis = 'author' AND term = ?",
                [.string("jane austen")]
            )
            return rows.first?.double("weight")
        }

        func state() async throws -> SignalState? {
            let rows = try await database.query(
                "SELECT max_completion, applied_increment FROM taste_signal_state WHERE book_id = ?",
                [ModelMapping.databaseValue(bookID)]
            )
            guard let row = rows.first,
                  let maxCompletion = row.double("max_completion"),
                  let appliedIncrement = row.double("applied_increment") else { return nil }
            return SignalState(maxCompletion: maxCompletion, appliedIncrement: appliedIncrement)
        }
    }

    private func makeHarness(named name: String) async throws -> Harness {
        let database = AppDatabase.makeTemporaryDatabase(named: name)
        let repository = LibraryRepository(database: database)
        let metadata = try metadataFixture()
        let imported = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        let terms = try await repository.fetchBookTasteTerms(for: imported.book.id)
        #expect(!(terms.isEmpty))  // fixture import must seed book_taste terms
        return Harness(
            database: database,
            store: TasteProfileStore(database: database),
            bookID: imported.book.id,
            terms: terms
        )
    }

    private func metadataFixture() throws -> InternetArchiveMetadata {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("InternetArchive", isDirectory: true)
            .appendingPathComponent("metadata_librivox_item.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(InternetArchiveMetadata.self, from: data)
    }
}
