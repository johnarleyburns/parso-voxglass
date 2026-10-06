import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

private struct PatchFixture: Codable, Equatable {
    var title: AuthoringPatch<String>
    enum CodingKeys: String, CodingKey { case title }
    init(title: AuthoringPatch<String>) { self.title = title }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodePatch(String.self, forKey: .title)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(title, forKey: .title)
    }
}

@Suite struct AuthoringV2Tests {
    @Test func projectBridgeBuildsPortableRecordsAndPreservesDeviceLocalTakes() throws {
        let projectID = UUID()
        let chapterID = UUID()
        let paragraphID = UUID()
        let takeID = UUID()
        let take = Take(
            id: takeID,
            paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: String(repeating: "a", count: 64), relativePath: "takes/one.wav", byteCount: 96, contentType: "audio/wav"),
            origin: .recorded,
            recordedAt: Date(timeIntervalSince1970: 100),
            duration: 2,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s16le"),
            textHashAtRecording: "old-hash"
        )
        let paragraph = Paragraph(
            id: paragraphID, ordinal: 0, text: "The original script.", textHash: "script-hash",
            takes: [take], selectedTakeID: takeID, updatedAt: Date(timeIntervalSince1970: 101)
        )
        let chapter = ProductionChapter(id: chapterID, ordinal: 0, title: "Chapter One", paragraphs: [paragraph])
        let project = AudiobookProject(
            id: projectID,
            metadata: BookMetadata(
                title: "A Test Book", author: "A. Writer", narrator: "Reader",
                coverRef: AudioAssetReference(sha256: String(repeating: "c", count: 64), relativePath: "artwork/cover.jpg", byteCount: 64, contentType: "image/jpeg")
            ),
            chapters: [chapter],
            createdAt: Date(timeIntervalSince1970: 90),
            modifiedAt: Date(timeIntervalSince1970: 102)
        )

        let snapshots = try AuthoringProjectBridge.records(for: project)
        #expect(snapshots.map(\.kind) == ["project", "chapter", "paragraph"])
        #expect(snapshots.allSatisfy { $0.payload.count < 512 * 1024 })
        let stored = snapshots.map {
            AuthoringStoredEntity(id: $0.id, kind: $0.kind, payload: $0.payload, isTombstoned: false)
        }
        let merge = try AuthoringProjectBridge.applying(stored, to: [project])
        let restored = try #require(merge.projects.first)
        #expect(restored.metadata.title == "A Test Book")
        #expect(restored.chapters.first?.paragraphs.first?.text == "The original script.")
        #expect(restored.chapters.first?.paragraphs.first?.takes == [take])
        #expect(restored.chapters.first?.paragraphs.first?.selectedTakeID == takeID)
        #expect(restored.metadata.coverRef?.relativePath == "artwork/cover.jpg")

        let paragraphSnapshot = try #require(snapshots.last)
        let authoringParagraph = try JSONDecoder().decode(AuthoringParagraph.self, from: paragraphSnapshot.payload)
        #expect(authoringParagraph.selectedTakeId == takeID)
        #expect(!String(decoding: paragraphSnapshot.payload, as: UTF8.self).contains("one.wav"))
        #expect(!String(decoding: snapshots[0].payload, as: UTF8.self).contains("cover.jpg"))
    }

    @Test func projectBridgeAppliesRemoteScriptEditsWithoutReplacingLocalAudio() throws {
        let projectID = UUID()
        let chapterID = UUID()
        let paragraphID = UUID()
        let takeID = UUID()
        let take = Take(
            id: takeID,
            paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: String(repeating: "b", count: 64), relativePath: "takes/local.wav", byteCount: 128, contentType: "audio/wav"),
            origin: .recorded,
            recordedAt: Date(timeIntervalSince1970: 200),
            duration: 3,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s16le"),
            textHashAtRecording: "before"
        )
        let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: "Before", textHash: "before", takes: [take], selectedTakeID: takeID)
        let project = AudiobookProject(
            id: projectID,
            metadata: BookMetadata(title: "Remote Edit", author: "Writer", narrator: "Reader"),
            chapters: [ProductionChapter(id: chapterID, ordinal: 0, title: "Chapter", paragraphs: [paragraph])]
        )
        let snapshots = try AuthoringProjectBridge.records(for: project)
        var remote = try JSONDecoder().decode(AuthoringParagraph.self, from: try #require(snapshots.last).payload)
        remote.text = "After"
        remote.textSha256 = "after"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed = snapshots
        changed[changed.count - 1].payload = try encoder.encode(remote)
        let stored = changed.map {
            AuthoringStoredEntity(id: $0.id, kind: $0.kind, payload: $0.payload, isTombstoned: false)
        }

        let merge = try AuthoringProjectBridge.applying(stored, to: [project])
        let updated = try #require(merge.projects.first?.chapters.first?.paragraphs.first)
        #expect(updated.text == "After")
        #expect(updated.textHash == "after")
        #expect(updated.takes == [take])
        #expect(updated.selectedTakeID == takeID)
    }

    @Test func bridgeTombstonesRemovedParagraphsAndProjects() throws {
        let projectID = UUID()
        let chapterID = UUID()
        let paragraphID = UUID()
        let chapter = AuthoringChapter(id: chapterID, projectId: projectID, ordinal: 0, title: "Chapter", role: "body", headGapFrames: 0, tailGapFrames: 0, sampleRate: 48_000)
        let paragraph = AuthoringParagraph(id: paragraphID, projectId: projectID, chapterId: chapterID, ordinal: 0, text: "Text", textSha256: "hash", selectionRevision: "r1")
        let existing = [
            AuthoringStoredEntity(id: chapterID, kind: "chapter", payload: try JSONEncoder().encode(chapter), isTombstoned: false),
            AuthoringStoredEntity(id: paragraphID, kind: "paragraph", payload: try JSONEncoder().encode(paragraph), isTombstoned: false)
        ]
        let desired = [AuthoringEntitySnapshot(id: projectID, kind: "project", payload: Data("{}".utf8), changedFields: [])]

        let deletions = AuthoringProjectBridge.deletionRecordsForRemovedChildren(in: existing, desiredSnapshots: desired)
        #expect(Set(deletions.map(\.id)) == [chapterID, paragraphID])
        #expect(deletions.allSatisfy { $0.kind.hasPrefix("tombstone_") })
    }

    @Test func portableProjectFixtureRoundTripsAndPreservesUnknownFields() throws {
        let url = try #require(Bundle.module.url(forResource: "cross-language-project", withExtension: "json", subdirectory: "AuthoringV2"))
        let fixture = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(AuthoringProject.self, from: fixture)
        #expect(project.protocolVersion == 2)
        #expect(project.title == "The Secret Garden")
        #expect(project.extensions["futureCapability"] == .string("preserved"))

        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AuthoringProject.self, from: encoded)
        #expect(decoded == project)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["futureCapability"] as? String == "preserved")
        #expect(object["modifiedAt"] as? String == "2026-10-05T15:04:05.125Z")
    }

    @Test func immutableCaptureAndMutableTakeStateKeepCompleteFidelity() throws {
        let takeID = try #require(UUID(uuidString: "20a24464-6d47-4f0e-8c44-e835db661b35"))
        let manifestID = try #require(UUID(uuidString: "4c97fe8f-8101-4678-b88a-19c29bfb58f9"))
        let capture = AuthoringTakeCapture(
            id: takeID, projectId: try #require(UUID(uuidString: "54d843b7-9307-45b0-a27e-9b43cf45cd59")),
            paragraphId: try #require(UUID(uuidString: "e2425ec8-7e76-4c15-8229-c8fb5e86d555")),
            capturedAt: "2026-10-05T15:04:05.125Z", origin: "importedHuman",
            recordedTextSha256: String(repeating: "a", count: 64), sampleRate: 48_000,
            channels: 1, bitsPerSample: 24, codec: "pcm_s24le", frameCount: 1_152_000,
            warning: "recoveredAfterInterruption", assetManifestId: manifestID,
            extensions: ["legacyOriginPayload": .string("source.wav")]
        )
        let state = AuthoringTakeState(
            takeId: takeID, label: "Pickup", archived: true,
            recipe: [AuthoringProcessingStep(kind: "gainDB", parameters: ["gain": -1.375])],
            recipeRevision: "r3", extensions: ["futureTakeState": .bool(true)]
        )
        #expect(try JSONDecoder().decode(AuthoringTakeCapture.self, from: JSONEncoder().encode(capture)) == capture)
        #expect(try JSONDecoder().decode(AuthoringTakeState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test func patchEncodingPreservesMissingClearAndValue() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PatchFixture.self, from: Data("{}".utf8)).title == .missing)
        #expect(try decoder.decode(PatchFixture.self, from: Data(#"{"title":null}"#.utf8)).title == .clear)
        #expect(try decoder.decode(PatchFixture.self, from: Data(#"{"title":"updated"}"#.utf8)).title == .set("updated"))
        let omitted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PatchFixture(title: .missing))) as? [String: Any]
        let cleared = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PatchFixture(title: .clear))) as? [String: Any]
        #expect(omitted?.keys.isEmpty == true)
        #expect(cleared?.keys.contains("title") == true && cleared?["title"] is NSNull)
    }

    @Test func localMutationAndOutboxCommitTogetherAndTriggerFailureRollsBackBoth() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_outbox_atomic")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 100)))
        let entityID = UUID()
        _ = try await store.commitLocalMutation(entityId: entityID, entityKind: "paragraph", payload: Data(#"{"text":"offline edit"}"#.utf8), changedFields: ["text"])
        let counts = try await database.query("SELECT (SELECT COUNT(*) FROM authoring_entity) AS entities, (SELECT COUNT(*) FROM authoring_outbox) AS pending")
        #expect(counts.first?.int("entities") == 1)
        #expect(counts.first?.int("pending") == 1)
        let pending = try await store.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending.first?.entityId == entityID)
        #expect(pending.first?.changedFields == ["text"])
        #expect(pending.first?.payload == Data(#"{"text":"offline edit"}"#.utf8))

        try await database.executeRaw("CREATE TRIGGER reject_authoring_outbox BEFORE INSERT ON authoring_outbox BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        let failedID = UUID()
        await #expect(throws: (any Error).self) {
            _ = try await store.commitLocalMutation(entityId: failedID, entityKind: "paragraph", payload: Data(#"{"text":"must roll back"}"#.utf8), changedFields: ["text"])
        }
        let failed = try await database.query("SELECT COUNT(*) AS c FROM authoring_entity WHERE id=?", [.string(failedID.uuidString)])
        #expect(failed.first?.int("c") == 0)
    }

    @Test func inboxApplyAndCursorCheckpointAreAtomicAndDoNotEchoToOutbox() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_inbox_atomic")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 101)))
        let remoteID = UUID()
        let record = AuthoringRemoteRecord(id: remoteID, kind: "takeCapture", changeTag: "tag-1", payload: Data(#"{"frameCount":96000}"#.utf8))
        try await store.applyRemotePage(scope: "private:user-a", pageId: UUID(), records: [record], cursor: Data(#"{"cursor":"next"}"#.utf8), engineState: Data([1, 2, 3]))
        try await store.applyRemotePage(scope: "private:user-a", pageId: UUID(), records: [record], cursor: Data(#"{"cursor":"next"}"#.utf8))
        #expect(try await store.cursor(scope: "private:user-a") == #"{"cursor":"next"}"#)
        let counts = try await database.query("SELECT (SELECT COUNT(*) FROM authoring_entity) AS entities, (SELECT COUNT(*) FROM authoring_outbox) AS pending, (SELECT COUNT(*) FROM authoring_inbox WHERE applied=1) AS applied")
        #expect(counts.first?.int("entities") == 1)
        #expect(counts.first?.int("pending") == 0)
        #expect(counts.first?.int("applied") == 1)

        try await database.executeRaw("CREATE TRIGGER reject_authoring_inbox BEFORE INSERT ON authoring_inbox BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        let failureScope = "private:user-b"
        let failed = AuthoringRemoteRecord(id: UUID(), kind: "paragraph", changeTag: "tag-x", payload: Data(#"{"text":"late"}"#.utf8))
        await #expect(throws: (any Error).self) {
            try await store.applyRemotePage(scope: failureScope, pageId: UUID(), records: [failed], cursor: Data(#"{"cursor":"must-not-advance"}"#.utf8))
        }
        #expect(try await store.cursor(scope: failureScope) == nil)
    }

    @Test func repeatedProjectAutosavesDoNotAppendDuplicateOutboxRows() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_snapshot_dedupe")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 100)))
        let entityID = UUID()
        let payload = Data(#"{"title":"Draft"}"#.utf8)
        #expect(try await store.commitLocalMutationIfChanged(entityId: entityID, entityKind: "project", payload: payload, changedFields: ["title"]) != nil)
        #expect(try await store.commitLocalMutationIfChanged(entityId: entityID, entityKind: "project", payload: payload, changedFields: ["title"]) == nil)
        #expect(try await store.pendingMutations().count == 1)
        #expect(try await store.entities().first?.payload == payload)
    }

    @Test func remoteUpdatesMergeDisjointFieldsAndPersistConflictingCandidates() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_three_way_merge")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 102)))
        let entityID = UUID()
        let scope = "private:user-a"
        let baseline = AuthoringRemoteRecord(id: entityID, kind: "paragraph", changeTag: "r1", payload: Data(#"{"text":"base","selectedTake":"one","direction":"quiet"}"#.utf8))
        try await store.applyRemotePage(scope: scope, pageId: UUID(), records: [baseline], cursor: nil)
        let localMutation = try await store.commitLocalMutation(entityId: entityID, entityKind: "paragraph", payload: Data(#"{"text":"local text","selectedTake":"local take","direction":"quiet"}"#.utf8), changedFields: ["text", "selectedTake"])
        #expect(localMutation.baseChangeTag == "r1")
        let remote = AuthoringRemoteRecord(id: entityID, kind: "paragraph", changeTag: "r2", payload: Data(#"{"text":"base","selectedTake":"remote take","direction":"brisk"}"#.utf8))
        try await store.applyRemotePage(scope: scope, pageId: UUID(), records: [remote], cursor: nil)

        let row = try await database.query("SELECT payload_json FROM authoring_entity WHERE id=?", [.string(entityID.uuidString)]).first
        let payload = try #require(row?.string("payload_json"))
        #expect(payload.contains("local text"))
        #expect(payload.contains("brisk"))
        let conflicts = try await database.query("SELECT field, local_json, remote_json FROM authoring_conflict WHERE entity_id=?", [.string(entityID.uuidString)])
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.string("field") == "selectedTake")
        #expect(conflicts.first?.string("local_json") == #""local take""#)
        #expect(conflicts.first?.string("remote_json") == #""remote take""#)
        #expect(try await database.query("SELECT operation_id FROM authoring_outbox WHERE state='pending'").count == 1)
    }

    @Test func remoteUpdatesMergeDisjointNestedMetadataAndNameNestedConflicts() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_nested_merge")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 102)))
        let entityID = UUID()
        let scope = "private:user-nested"
        try await store.applyRemotePage(scope: scope, pageId: UUID(), records: [
            AuthoringRemoteRecord(id: entityID, kind: "project", changeTag: "r1", payload: Data(#"{"metadata":{"author":"Base","narrator":"Base"},"title":"Base"}"#.utf8))
        ], cursor: nil)
        _ = try await store.commitLocalMutation(
            entityId: entityID, entityKind: "project",
            payload: Data(#"{"metadata":{"author":"Local","narrator":"Base"},"title":"Base"}"#.utf8),
            changedFields: ["metadata.author"]
        )
        try await store.applyRemotePage(scope: scope, pageId: UUID(), records: [
            AuthoringRemoteRecord(id: entityID, kind: "project", changeTag: "r2", payload: Data(#"{"metadata":{"author":"Remote","narrator":"New Narrator"},"title":"Base"}"#.utf8))
        ], cursor: nil)

        let payload = try #require(try await database.query("SELECT payload_json FROM authoring_entity WHERE id=?", [.string(entityID.uuidString)]).first?.string("payload_json"))
        #expect(payload.contains("\"author\":\"Local\""))
        #expect(payload.contains("\"narrator\":\"New Narrator\""))
        #expect(try await database.query("SELECT field FROM authoring_conflict WHERE entity_id=?", [.string(entityID.uuidString)]).first?.string("field") == "metadata.author")
    }

    @Test func engineCheckpointAndUploadReceiptSurviveStoreReopen() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_engine_checkpoint")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 103)))
        let entityID = UUID()
        let mutation = try await store.commitLocalMutation(
            entityId: entityID, entityKind: "project", payload: Data(#"{"title":"Draft"}"#.utf8), changedFields: ["title"]
        )
        let state = Data([0, 1, 2, 255])
        try await store.saveEngineState(scope: "private:authoring-v2", state: state)
        #expect(try await store.engineState(scope: "private:authoring-v2") == state)

        let systemFields = Data([7, 8, 9])
        try await store.acknowledgeUpload(entityId: entityID, operationId: mutation.operationId, changeTag: "tag-2", systemFields: systemFields)
        #expect(try await store.pendingMutations().isEmpty)
        #expect(try await store.systemFields(entityId: entityID) == systemFields)
        let row = try await database.query("SELECT server_change_tag, server_base_json FROM authoring_entity WHERE id=?", [.string(entityID.uuidString)]).first
        #expect(row?.string("server_change_tag") == "tag-2")
        #expect(row?.string("server_base_json") == #"{"title":"Draft"}"#)
        #expect(try await database.query("SELECT operation_id FROM authoring_receipt WHERE operation_id=?", [.string(mutation.operationId.uuidString)]).count == 1)
    }

    @Test func remoteDeletionWithPendingEditRetainsCandidateInsteadOfDroppingLocalWork() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_delete_conflict")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 104)))
        let entityID = UUID()
        try await store.applyRemotePage(scope: "private:authoring-v2", pageId: UUID(), records: [
            AuthoringRemoteRecord(id: entityID, kind: "project", changeTag: "tag-1", payload: Data(#"{"title":"Before"}"#.utf8))
        ], cursor: nil)
        _ = try await store.commitLocalMutation(entityId: entityID, entityKind: "project", payload: Data(#"{"title":"Offline edit"}"#.utf8), changedFields: ["title"])
        try await store.applyRemotePage(scope: "private:authoring-v2", pageId: UUID(), records: [
            AuthoringRemoteRecord(id: entityID, kind: "project", changeTag: "deleted", payload: Data("null".utf8), isDeleted: true)
        ], cursor: nil)

        #expect(try await store.hasUnresolvedConflicts(entityId: entityID))
        let row = try await database.query("SELECT payload_json, tombstoned FROM authoring_entity WHERE id=?", [.string(entityID.uuidString)]).first
        #expect(row?.string("payload_json")?.contains("Offline edit") == true)
        #expect(row?.int("tombstoned") == 0)
        #expect(try await database.query("SELECT field FROM authoring_conflict WHERE entity_id=?", [.string(entityID.uuidString)]).first?.string("field") == "$deleted")
    }

    @Test func replayedRemoteDeletionCreatesOneTombstone() async throws {
        let database = ProjectDatabase.makeTemporary(named: "authoring_delete_replay")
        let store = AuthoringLocalStore(databaseURL: database.url, clock: FixedClock(Date(timeIntervalSince1970: 105)))
        let entityID = UUID()
        let deletion = AuthoringRemoteRecord(id: entityID, kind: "paragraph", changeTag: "deleted-v2", payload: Data("null".utf8), isDeleted: true)
        try await store.applyRemotePage(scope: "private:authoring-v2", pageId: UUID(), records: [deletion], cursor: nil)
        try await store.applyRemotePage(scope: "private:authoring-v2", pageId: UUID(), records: [deletion], cursor: nil)
        #expect(try await database.query("SELECT operation_id FROM authoring_tombstone WHERE entity_id=?", [.string(entityID.uuidString)]).count == 1)
    }
}
