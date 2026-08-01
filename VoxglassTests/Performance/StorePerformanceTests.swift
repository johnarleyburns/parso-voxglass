import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §19.3 / §7.5: `paragraphSummaries` on the 10,000-¶ fixture < 120 ms
/// and `counts()` < 20 ms — both MUST be single SQL statements over SQLite,
/// not a full project load. Use the on-disk store so the query path is real.
///
/// Timing tests live in this dedicated `VoxglassPerformanceTests` target so
/// they run serially (`--no-parallel --filter VoxglassPerformanceTests`) and
/// never contend with the parallel logic suites for CPU. Budgets are asserted
/// as the best of several runs so transient CI-runner jitter never produces a
/// false failure.
@Suite(.serialized) struct StorePerformanceTests {
    private func onDiskStore() async throws -> SQLiteProductionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SQLiteProductionStore(databaseURL: dir.appendingPathComponent("perf.sqlite"))
        let project = ProjectFixtures.stress(paragraphs: 10_000)
        try await store.save(project)
        return store
    }

    private func bestOf(_ iterations: Int, _ body: () async throws -> Void) async throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let start = DispatchTime.now()
            try await body()
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMS)
        }
        return best
    }

    @Test func paragraphSummariesUnder120ms() async throws {
        let store = try await onDiskStore()

        // Warm the page cache before measuring.
        _ = try await store.paragraphSummaries(chapterID: nil)

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.count == 10_000)

        let elapsedMS = try await bestOf(3) {
            _ = try await store.paragraphSummaries(chapterID: nil)
        }
        #expect(elapsedMS < 120, "paragraphSummaries took \(elapsedMS) ms, budget is 120 ms")
    }

    @Test func countsUnder20ms() async throws {
        let store = try await onDiskStore()
        _ = try await store.counts()

        let counts = try await store.counts()
        #expect(counts.paragraphs == 10_000)

        let elapsedMS = try await bestOf(3) {
            _ = try await store.counts()
        }
        #expect(elapsedMS < 20, "counts() took \(elapsedMS) ms, budget is 20 ms")
    }
}
