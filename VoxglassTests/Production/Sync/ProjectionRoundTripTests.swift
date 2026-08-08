import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct ProjectionRoundTripTests {

    private let codec = ProjectionRecordCodec()

    /// A projection whose summary fields survive the record codec unchanged
    /// (no cover ref, revision consistent between `revision` and `projectionRevision`).
    private func makeProjection(revision: Int = 3) -> SyncProjection {
        let projectID = UUID(uuidString: "6C6B36F5-1111-2222-3333-444444444444")!
        let chapterID = UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
        let paragraphID = UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-EEEEEEEEEEEE")!

        let summary = ProjectSummary(
            id: projectID,
            title: "Round Trip",
            author: "Author",
            narrator: "Narrator",
            percentRecorded: 0.5,
            recordedCount: 1,
            totalCount: 2,
            flaggedCount: 1,
            needsPickupCount: 0,
            unapprovedCount: 1,
            readyToExport: false,
            purpose: .publicDomainCommunity,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            coverRef: nil,
            isHiddenFromDevices: false,
            projectionRevision: revision
        )

        return SyncProjection(
            project: summary,
            chapters: [
                ChapterProjection(
                    id: chapterID, projectID: projectID, ordinal: 0, title: "Ch 1",
                    role: .body, paragraphCount: 2, recordedCount: 1, duration: 5
                )
            ],
            paragraphs: [
                ParagraphProjection(
                    id: paragraphID, chapterID: chapterID, projectID: projectID,
                    ordinal: 0, globalOrdinal: 0, text: "Recorded para", reviewState: .flagged,
                    takeID: UUID(), duration: 5, proxySourceSHA: "sha-1",
                    latestNoteText: "Note", latestNoteTag: .pacing, originKind: "recorded"
                ),
                ParagraphProjection(
                    id: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-FFFFFFFFFFFF")!,
                    chapterID: chapterID, projectID: projectID,
                    ordinal: 1, globalOrdinal: 1, text: "Unrecorded para", reviewState: .unreviewed,
                    takeID: nil, duration: 0, proxySourceSHA: nil,
                    latestNoteText: nil, latestNoteTag: nil, originKind: "none"
                )
            ],
            revision: revision,
            narrationOrigin: .humanOnly,
            watchPinnedParagraphIDs: [paragraphID]
        )
    }

    @Test func projection_roundTripsThroughRecords() {
        let original = makeProjection()
        let records = codec.records(from: original)
        #expect(records.count == 1 + 1 + 2)

        let decoded = codec.projection(from: records)
        #expect(decoded == original)
    }

    @Test func nilFields_arePreservedAsMissing() {
        let original = makeProjection()
        let records = codec.records(from: original)
        let unrecorded = records.first { $0.recordName.hasPrefix("para-") && $0.fields["takeID"] == nil }!

        #expect(unrecorded.fields["proxySHA"] == nil)
        #expect(unrecorded.fields["latestNoteText"] == nil)
        #expect(unrecorded.fields["latestNoteTag"] == nil)

        let decoded = codec.projection(from: records)
        let para = decoded!.paragraphs.first { $0.takeID == nil }!
        #expect(para.text == "Unrecorded para")
        #expect(para.proxySourceSHA == nil)
        #expect(para.originKind == "none")
    }

    @Test func recordFieldNames_matchSpec() {
        let records = codec.records(from: makeProjection())

        let project = records.first { $0.recordType == "VGProductionProject" }!
        #expect(project.recordName.hasPrefix("project-"))
        #expect(project.fields["revision"] == .int64(3))
        #expect(project.fields["pinnedIDs"] == .stringList(["6C6B36F5-AAAA-BBBB-CCCC-EEEEEEEEEEEE"]))
        #expect(project.fields["isHidden"] == .int64(0))

        let paragraph = records.first { $0.fields["proxySHA"] != nil }!
        #expect(paragraph.recordType == "VGProductionParagraph")
        #expect(paragraph.recordName.hasPrefix("para-"))
        #expect(paragraph.parentName?.hasPrefix("chapter-") == true)
        #expect(paragraph.fields["originKind"] == .string("recorded"))
    }

    @Test func event_roundTripsThroughRecord() {
        let event = ReviewEvent(
            id: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-000000000001")!,
            projectID: UUID(uuidString: "6C6B36F5-1111-2222-3333-444444444444")!,
            paragraphID: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-EEEEEEEEEEEE")!,
            type: .addNote,
            noteText: "Slow down here",
            tag: .pacing,
            device: .watch,
            createdAt: Date(timeIntervalSince1970: 1_700_000_123)
        )

        let record = codec.eventRecord(from: event)
        #expect(record.recordType == "VGReviewEvent")
        #expect(record.recordName == "event-\(event.id.uuidString)")
        #expect(record.fields["type"] == .string("addNote"))
        #expect(record.fields["tag"] == .string("pacing"))

        let decoded = codec.event(from: record)
        #expect(decoded?.id == event.id)
        #expect(decoded?.type == event.type)
        #expect(decoded?.noteText == event.noteText)
        #expect(decoded?.tag == event.tag)
        #expect(decoded?.device == event.device)
        #expect(decoded?.createdAt == event.createdAt)
        #expect(decoded?.origin == .cloud)
    }

    @Test func eventWithoutOptionalFields_roundTrips() {
        let event = ReviewEvent(
            id: UUID(), projectID: UUID(), paragraphID: UUID(),
            type: .flag, noteText: nil, tag: nil, device: .iPhone,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        let decoded = codec.event(from: codec.eventRecord(from: event))
        #expect(decoded == ReviewEvent(
            id: event.id, projectID: event.projectID, paragraphID: event.paragraphID,
            type: .flag, noteText: nil, tag: nil, device: .iPhone,
            createdAt: event.createdAt, appliedAt: nil, origin: .cloud
        ))
    }

    @Test func assetRecord_roundTripsThroughCodec() {
        let mirror = AssetMirrorRecord(
            id: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-00000000000A")!,
            sha256: "deadbeef",
            byteCount: 42,
            ext: "wav",
            contentType: "audio/wav",
            takeID: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-00000000000B")!,
            chapterID: UUID(uuidString: "6C6B36F5-AAAA-BBBB-CCCC-00000000000C")!
        )

        let record = codec.assetRecord(from: mirror)
        #expect(record.recordType == "VGProductionAsset")
        #expect(record.recordName == "asset-\(mirror.id.uuidString)")
        #expect(record.fields["sha256"] == .string("deadbeef"))
        #expect(record.fields["byteCount"] == .int64(42))
        #expect(record.fields["ext"] == .string("wav"))

        let decoded = codec.assetMirror(from: record)
        #expect(decoded == mirror)
    }

    @Test func assetRecord_withoutLinkage_roundTripsWithNilLinkage() {
        let mirror = AssetMirrorRecord(
            id: UUID(), sha256: "sha", byteCount: 10, ext: "caf", contentType: "audio/x-caf"
        )
        let decoded = codec.assetMirror(from: codec.assetRecord(from: mirror))
        #expect(decoded?.id == mirror.id)
        #expect(decoded?.takeID == nil)
        #expect(decoded?.chapterID == nil)
    }

    // MARK: - Diff

    @Test func diff_noChangesWhenIdentical() {
        let projection = makeProjection()
        let changes = ProjectionDiff.diff(old: projection, new: projection)
        #expect(changes.isEmpty)
    }

    @Test func diff_singleParagraphChange_producesOneModification() {
        let old = makeProjection()
        var new = old
        let paragraphID = old.paragraphs[0].id
        new.paragraphs[0].proxySourceSHA = "sha-2"
        new.paragraphs[0].reviewState = .approved

        let changes = ProjectionDiff.diff(old: old, new: new)
        #expect(changes.count == 1)
        #expect(changes[0].kind == .upsert)
        #expect(changes[0].recordName == "para-\(paragraphID.uuidString)")
        #expect(changes[0].proxyNeeded == true)
        #expect(changes[0].fields["proxySHA"] == .string("sha-2"))
    }

    @Test func diff_addedParagraph_isUpsertWithProxy() {
        let old = makeProjection()
        var new = old
        let newParagraph = ParagraphProjection(
            id: UUID(), chapterID: old.paragraphs[0].chapterID, projectID: old.project.id,
            ordinal: 2, globalOrdinal: 2, text: "New", reviewState: .unreviewed,
            takeID: UUID(), duration: 2, proxySourceSHA: "sha-new", originKind: "recorded"
        )
        new.paragraphs.append(newParagraph)

        let changes = ProjectionDiff.diff(old: old, new: new)
        let added = changes.first { $0.recordName == "para-\(newParagraph.id.uuidString)" }
        #expect(added?.kind == .upsert)
        #expect(added?.proxyNeeded == true)
    }

    @Test func diff_removedParagraph_isDelete() {
        let old = makeProjection()
        var new = old
        let removedID = old.paragraphs[0].id
        new.paragraphs.removeAll { $0.id == removedID }

        let changes = ProjectionDiff.diff(old: old, new: new)
        let deletion = changes.first { $0.recordName == "para-\(removedID.uuidString)" }
        #expect(deletion?.kind == .delete)
    }

    @Test func diff_sameSHA_noProxyNeeded() {
        let old = makeProjection()
        var new = old
        new.paragraphs[0].reviewState = .approved
        // Only the review state changed; the source audio (and its proxy) is unchanged.
        let changes = ProjectionDiff.diff(old: old, new: new)
        #expect(changes.count == 1)
        #expect(changes[0].proxyNeeded == false)
    }
}
