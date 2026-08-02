import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct SyncTokenRecoveryTests {

    private var noOpConfig: ProductionSyncEngine.Configuration {
        ProductionSyncEngine.Configuration(sleeper: { _ in }, randomJitter: { 1.0 })
    }

    @Test func staleToken_recoversSilentlyWithFullRefetch() async throws {
        let project = ProjectFixtures.tiny()
        let projection = ProjectionBuilder().projection(from: project, counts: counts(for: project), revision: 4)!
        let codec = ProjectionRecordCodec()

        let transport = FakeProductionSyncTransport()
        transport.seed(codec.records(from: projection))
        // The stored token is stale: the server rejects it once.
        transport.expireTokenOnce = true

        let state = InMemorySyncStateStore()
        try await state.setChangeToken(SyncChangeToken(data: Data("g-stale".utf8)))
        let engine = ProductionSyncEngine(transport: transport, state: state, config: noOpConfig)

        // First pump: the stale token is discarded and the zone refetched from
        // scratch — no error surfaces, everything is recovered.
        let report = try await engine.pump()

        #expect(report.fullRefetchUsed == true)
        #expect(report.projection?.revision == 4)
        #expect(report.projection?.paragraphs.count == project.totalCount)
        #expect(report.events.isEmpty)

        // The token store now holds the fresh token, not the stale one.
        let freshToken = try await state.changeToken()
        #expect(freshToken != nil)
        #expect(freshToken?.data != Data("g-stale".utf8))
    }

    @Test func subsequentPumps_areIncremental() async throws {
        let project = ProjectFixtures.tiny()
        let projection = ProjectionBuilder().projection(from: project, counts: counts(for: project), revision: 4)!
        let codec = ProjectionRecordCodec()

        let transport = FakeProductionSyncTransport()
        transport.seed(codec.records(from: projection))
        let state = InMemorySyncStateStore()
        let engine = ProductionSyncEngine(transport: transport, state: state, config: noOpConfig)

        let first = try await engine.pump()
        #expect(first.fullRefetchUsed == false)
        #expect(first.projection != nil)

        // Nothing changed server-side, so the second pump fetches no records.
        let second = try await engine.pump()
        #expect(second.fullRefetchUsed == false)
        #expect(second.projection == nil)
        #expect(second.events.isEmpty)
    }

    @Test func tokenExpiryDuringStream_doesNotLoseRecords() async throws {
        let project = ProjectFixtures.librivoxReady()
        let projection = ProjectionBuilder().projection(from: project, counts: counts(for: project), revision: 9)!
        let codec = ProjectionRecordCodec()

        let transport = FakeProductionSyncTransport()
        transport.seed(codec.records(from: projection))
        transport.expireTokenOnce = true
        let state = InMemorySyncStateStore()
        try await state.setChangeToken(SyncChangeToken(data: Data("g-1".utf8)))
        let engine = ProductionSyncEngine(transport: transport, state: state, config: noOpConfig)

        let report = try await engine.pump()
        #expect(report.fullRefetchUsed == true)
        // The full record set is recovered despite the token being rejected.
        #expect(report.projection?.paragraphs.count == project.totalCount)
    }
}
