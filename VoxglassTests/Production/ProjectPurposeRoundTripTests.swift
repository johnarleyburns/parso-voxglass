import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// G12/F5 — the project purpose the user picks on the new-project step must
/// persist: it round-trips through the SQLite store and the CloudKit
/// projection (and the LibriVox manifest, asserted in `ExportEndToEndTests`).
@Suite struct ProjectPurposeRoundTripTests {

    @Test func purposeRoundTripsThroughStore() async throws {
        let store = InMemoryProductionStore()
        var project = ProjectFixtures.typical()
        project.profile.purpose = .commercial
        try await store.save(project)

        let loaded = try await store.load()
        #expect(loaded.profile.purpose == .commercial)
    }

    @Test func purposeRoundTripsThroughProjection() async throws {
        var project = ProjectFixtures.typical()
        project.profile.purpose = .personal
        let counts = ProjectCounts(
            paragraphs: project.totalCount,
            recorded: project.recordedCount,
            flagged: project.allParagraphs.count { $0.reviewState == .flagged },
            chapters: project.chapters.count
        )
        let projection = ProjectionBuilder().projection(from: project, counts: counts, revision: 1)

        #expect(projection?.project.purpose == .personal)
    }
}
