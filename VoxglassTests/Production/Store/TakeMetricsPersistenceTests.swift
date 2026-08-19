import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// 2026-08-19 field report, item 12: "my quality metrics are always missing
/// when I do 'Check my recording'".
///
/// `setTakeMetrics` writes analysis straight to the take row, so any in-memory
/// graph loaded before that write carries `metrics == nil`. Saving is a
/// delete-and-reinsert, which used to erase the analysis on the very next save.
@Suite struct TakeMetricsPersistenceTests {

    private func sampleMetrics() -> AudioQualityMetrics {
        AudioQualityMetrics(
            peakDBFS: -6,
            truePeakDBFS: -5.5,
            rmsDBFS: -21,
            noiseFloorDBFS: -62,
            noiseFloorReliable: true,
            replayGainDB: 2.5,
            clipCount: 0,
            dcOffset: 0.0001,
            leadingSilence: 0.3,
            trailingSilence: 0.6,
            duration: 9.5,
            sampleRate: 44_100,
            channels: 1,
            computedAt: Date(timeIntervalSince1970: 1_700_000_000),
            analyzerVersion: AudioMetricsCalculator.analyzerVersion
        )
    }

    private func firstSelectedTakeID(_ project: AudiobookProject) -> UUID? {
        project.allParagraphs.compactMap(\.selectedTakeID).first
    }

    @Test func aFullProjectSaveDoesNotEraseAnalyzedMetrics() async throws {
        let db = ProjectDatabase.makeTemporary(named: "take-metrics-preserved")
        let store = SQLiteProductionStore(databaseURL: db.url)
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let takeID = try #require(firstSelectedTakeID(project))
        try await store.setTakeMetrics(sampleMetrics(), forTake: takeID)

        // The narrator keeps working from the graph they already had, which has
        // no metrics on that take, and something triggers a save.
        #expect(project.allParagraphs.flatMap(\.takes).first { $0.id == takeID }?.metrics == nil)
        try await store.save(project)

        let reloaded = try await store.load()
        let take = try #require(reloaded.allParagraphs.flatMap(\.takes).first { $0.id == takeID })
        #expect(take.metrics == sampleMetrics(), "analysis must survive a whole-project save")
    }

    @Test func aReAnalysisStillReplacesStoredMetrics() async throws {
        let db = ProjectDatabase.makeTemporary(named: "take-metrics-replaced")
        let store = SQLiteProductionStore(databaseURL: db.url)
        var project = ProjectFixtures.typical()
        try await store.save(project)

        let takeID = try #require(firstSelectedTakeID(project))
        try await store.setTakeMetrics(sampleMetrics(), forTake: takeID)

        var replacement = sampleMetrics()
        replacement.replayGainDB = -7.25
        for chapterIndex in project.chapters.indices {
            for paragraphIndex in project.chapters[chapterIndex].paragraphs.indices {
                guard let takeIndex = project.chapters[chapterIndex].paragraphs[paragraphIndex]
                    .takes.firstIndex(where: { $0.id == takeID }) else { continue }
                project.chapters[chapterIndex].paragraphs[paragraphIndex].takes[takeIndex].metrics = replacement
            }
        }
        try await store.save(project)

        let reloaded = try await store.load()
        let take = try #require(reloaded.allParagraphs.flatMap(\.takes).first { $0.id == takeID })
        #expect(take.metrics?.replayGainDB == -7.25, "carrying forward must never shadow a real re-analysis")
    }

    @Test func theInMemoryStoreCarriesMetricsForwardTheSameWay() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.typical()
        try await store.save(project)

        let takeID = try #require(firstSelectedTakeID(project))
        try await store.setTakeMetrics(sampleMetrics(), forTake: takeID)
        try await store.save(project)

        let reloaded = try await store.load()
        #expect(reloaded.allParagraphs.flatMap(\.takes).first { $0.id == takeID }?.metrics == sampleMetrics())
    }
}
