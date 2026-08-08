import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct SyncConflictTests {

    private var noOpConfig: ProductionSyncEngine.Configuration {
        ProductionSyncEngine.Configuration(sleeper: { _ in }, randomJitter: { 1.0 })
    }

    @Test func publishConflict_adoptsServerRevisionAndRetriesOnce() async throws {
        let project = ProjectFixtures.librivoxReady()
        let projectName = "project-\(project.id.uuidString)"

        // A competing Mac already published revision 2; our publish conflicts once.
        let transport = FakeProductionSyncTransport()
        transport.serverRevisionOnConflict = 2
        transport.conflictOnRecord = projectName

        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)
        let outcome = try await engine.publish(project: project, counts: counts(for: project))

        guard case let .published(revision, _, _) = outcome else {
            Issue.record("expected .published, got \(outcome)")
            return
        }
        // max(local 1, server 2 + 1) — last writer wins, adopting the server's head.
        #expect(revision == 3)

        // The server now holds the retried record with the adopted revision and the
        // conflict's change tag.
        let serverProject = transport.record(named: projectName)
        #expect(serverProject?.fields["revision"] == .int64(3))
        #expect(serverProject?.recordChangeTag == "conflict-after-nil"
            || serverProject?.recordChangeTag == transport.conflictChangeTag)
    }

    /// §4.2: the conflict branch degrades to adopt-server-tag, retry-once, phone
    /// wins — no conflict is ever surfaced. The publish must never throw and must
    /// always resolve to a published/withdrawn outcome, so there is no reachable
    /// user-visible conflict UI path.
    @Test func publishConflict_neverSurfacesToUser() async throws {
        let project = ProjectFixtures.librivoxReady()
        let projectName = "project-\(project.id.uuidString)"

        let transport = FakeProductionSyncTransport()
        transport.serverRevisionOnConflict = 4
        transport.conflictOnRecord = projectName

        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)
        let outcome = try await engine.publish(project: project, counts: counts(for: project))

        // The conflict was absorbed: the outcome is a normal publish result and no
        // error escaped to a caller that might render it.
        switch outcome {
        case .published(let revision, _, _):
            #expect(revision == 5)
        case .noChanges, .withdrawn:
            Issue.record("conflict publish must land, got \(outcome)")
        case .skipped:
            Issue.record("conflict publish must not be skipped, got \(outcome)")
        }

        // The engine's snapshot now matches the server head, so the next publish is
        // a clean no-change — the retry-once path fully converged.
        let again = try await engine.publish(project: project, counts: counts(for: project))
        #expect(again == .noChanges)
    }

    @Test func identicalPublish_isNoChange() async throws {
        let project = ProjectFixtures.librivoxReady()
        let transport = FakeProductionSyncTransport()
        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)

        let first = try await engine.publish(project: project, counts: counts(for: project))
        guard case .published(let revision, _, _) = first else {
            Issue.record("expected first publish to publish")
            return
        }
        #expect(revision == 1)

        // Nothing changed since the last snapshot — a publish is a no-op and does
        // not bump the revision (spec §13.5 "Delta only").
        let second = try await engine.publish(project: project, counts: counts(for: project))
        #expect(second == .noChanges)
    }

    @Test func transientFailure_retriesToCompletion() async throws {
        let project = ProjectFixtures.librivoxReady()
        let transport = FakeProductionSyncTransport()
        transport.transientFailuresRemaining = 1
        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)

        let outcome = try await engine.publish(project: project, counts: counts(for: project))
        guard case .published = outcome else {
            Issue.record("expected publish to succeed after a transient retry")
            return
        }

        let pushed = transport.pushedProjectionRecords()
        let expected = 1 + project.chapters.count + project.totalCount
        #expect(pushed.count == expected)
    }

    @Test func hiddenProject_withdrawsPublishedRecords() async throws {
        let project = ProjectFixtures.librivoxReady()
        let transport = FakeProductionSyncTransport()
        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)

        let first = try await engine.publish(project: project, counts: counts(for: project))
        guard case .published = first else {
            Issue.record("expected first publish to publish")
            return
        }
        #expect(!transport.pushedProjectionRecords().isEmpty)

        // Now hide the project: the published records are withdrawn.
        var hidden = project
        hidden.profile.isHiddenFromDevices = true
        let outcome = try await engine.publish(project: hidden, counts: counts(for: hidden))
        #expect(outcome == .withdrawn)
        #expect(transport.pushedProjectionRecords().isEmpty)
    }

    @Test func singleRerecordedParagraph_pushesOnlyOneDelta() async throws {
        let project = ProjectFixtures.librivoxReady()
        let transport = FakeProductionSyncTransport()
        let engine = ProductionSyncEngine(transport: transport, state: InMemorySyncStateStore(), config: noOpConfig)

        _ = try await engine.publish(project: project, counts: counts(for: project))
        let pushedAfterFirst = transport.pushedProjectionRecords().count

        // Re-record one paragraph: a new take with a different asset hash.
        var rerecorded = project
        let paragraphIndex = 1
        let paragraph = rerecorded.chapters[0].paragraphs[paragraphIndex]
        var takes = paragraph.takes
        let newTake = Take(
            id: UUID(), paragraphID: paragraph.id,
            assetRef: AudioAssetReference(sha256: "sha-new", relativePath: "new.wav", byteCount: 1, contentType: "public.wav"),
            origin: .recorded, recordedAt: Date(timeIntervalSince1970: 1),
            duration: 5,
            format: AudioFormatDescription(sampleRate: 44_100, channels: 1, codec: "pcm"),
            textHashAtRecording: paragraph.textHash
        )
        takes.append(newTake)
        rerecorded.chapters[0].paragraphs[paragraphIndex].takes = takes
        rerecorded.chapters[0].paragraphs[paragraphIndex].selectedTakeID = newTake.id

        let outcome = try await engine.publish(project: rerecorded, counts: counts(for: rerecorded))
        guard case let .published(_, recordsPushed, assetsPushed) = outcome else {
            Issue.record("expected publish to be a delta")
            return
        }
        // Project record + one paragraph record; exactly one new proxy asset.
        #expect(recordsPushed == 2)
        #expect(assetsPushed == 1)
        _ = pushedAfterFirst
    }
}
