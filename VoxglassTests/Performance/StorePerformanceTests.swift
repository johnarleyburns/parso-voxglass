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
/// never contend with the parallel logic suites for CPU.
@Suite(.serialized) struct StorePerformanceTests {
    private func onDiskStore() async throws -> SQLiteProductionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SQLiteProductionStore(databaseURL: dir.appendingPathComponent("perf.sqlite"))
        let project = ProjectFixtures.stress(paragraphs: 10_000)
        try await store.save(project)
        return store
    }

    @Test func paragraphSummariesUnder120ms() async throws {
        let store = try await onDiskStore()

        // Warm the page cache before measuring.
        _ = try await store.paragraphSummaries(chapterID: nil)

        let start = DispatchTime.now()
        let summaries = try await store.paragraphSummaries(chapterID: nil)
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        #expect(summaries.count == 10_000)
        #expect(elapsedMS < 120, "paragraphSummaries took \(elapsedMS) ms, budget is 120 ms")
    }

    @Test func countsUnder20ms() async throws {
        let store = try await onDiskStore()
        _ = try await store.counts()

        let start = DispatchTime.now()
        let counts = try await store.counts()
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        #expect(counts.paragraphs == 10_000)
        #expect(elapsedMS < 20, "counts() took \(elapsedMS) ms, budget is 20 ms")
    }
}
