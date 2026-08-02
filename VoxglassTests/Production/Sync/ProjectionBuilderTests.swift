import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct ProjectionBuilderTests {

    private func makeProject() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let paragraph = Paragraph(
            id: ids.next(),
            ordinal: 0,
            text: "Body paragraph.",
            textHash: SHA256Hex.hex(Data("Body paragraph.".utf8))
        )
        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Title", author: "Author", narrator: "Narrator"),
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "Ch", paragraphs: [paragraph])],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    @Test func unrecordedParagraph_projectsWithoutAudio() {
        let project = makeProject()
        let builder = ProjectionBuilder()
        let projection = builder.projection(from: project, counts: counts(for: project), revision: 0)

        #expect(projection != nil)
        let paragraph = projection?.paragraphs[0]
        #expect(paragraph?.takeID == nil)
        #expect(paragraph?.proxySourceSHA == nil)
        #expect(paragraph?.originKind == "none")
        // Unrecorded paragraphs still appear so the phone can show progress.
        #expect(paragraph?.text == "Body paragraph.")
        #expect(projection?.project.totalCount == 1)
        #expect(projection?.project.recordedCount == 0)
    }

    @Test func onlySelectedTake_isProjected() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let paragraphID = ids.next()
        let takeA = Take(
            id: ids.next(), paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "sha-a", relativePath: "a.wav", byteCount: 1, contentType: "public.wav"),
            origin: .recorded, recordedAt: clock.now, duration: 3,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        let takeB = Take(
            id: ids.next(), paragraphID: paragraphID,
            assetRef: AudioAssetReference(sha256: "sha-b", relativePath: "b.wav", byteCount: 1, contentType: "public.wav"),
            origin: .recorded, recordedAt: clock.now, duration: 4,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        let paragraph = Paragraph(
            id: paragraphID, ordinal: 0, text: "T", textHash: "h",
            takes: [takeA, takeB], selectedTakeID: takeB.id
        )
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "C", paragraphs: [paragraph])],
            createdAt: clock.now, modifiedAt: clock.now
        )

        let projection = ProjectionBuilder().projection(from: project, counts: counts(for: project), revision: 0)
        let projected = projection?.paragraphs[0]
        #expect(projected?.takeID == takeB.id)
        #expect(projected?.proxySourceSHA == "sha-b")
        #expect(projected?.duration == 4)
        // Alternate take A never leaves the Mac.
        #expect(projected?.proxySourceSHA != "sha-a")
        #expect(projection?.project.recordedCount == 1)
    }

    @Test func aiSelectedTaints_narrationOrigin_and_originKind() {
        let tainted = ProjectionBuilder().projection(from: ProjectFixtures.aiTainted(), counts: counts(for: ProjectFixtures.aiTainted()), revision: 0)
        #expect(tainted?.narrationOrigin == .containsImportedAI)
        #expect(tainted?.paragraphs[0].originKind == "aiImported")
        #expect(tainted?.paragraphs[0].takeID != nil)
    }

    @Test func aiUnselected_doesNotTaint() {
        let unselected = ProjectFixtures.aiUnselected()
        let projection = ProjectionBuilder().projection(from: unselected, counts: counts(for: unselected), revision: 0)
        #expect(projection?.narrationOrigin == .humanOnly)
        #expect(projection?.paragraphs[0].originKind == "none")
        #expect(projection?.paragraphs[0].takeID == nil)
    }

    @Test func hiddenProject_returnsNil() {
        let project = makeProject()
        var hidden = project
        hidden.profile.isHiddenFromDevices = true
        let projection = ProjectionBuilder().projection(from: hidden, counts: counts(for: hidden), revision: 0)
        #expect(projection == nil)
    }

    @Test func textOmitted_whenIncludeSourceTextDisabled() {
        let project = makeProject()
        let builder = ProjectionBuilder(policy: ProjectionPolicy(includeSourceText: false))
        let projection = builder.projection(from: project, counts: counts(for: project), revision: 0)
        #expect(projection?.paragraphs[0].text == nil)
    }

    @Test func countsAndRevision_mapIntoSummary() {
        let project = ProjectFixtures.librivoxReady()
        let revision = 7
        let projection = ProjectionBuilder().projection(from: project, counts: counts(for: project), revision: revision)

        #expect(projection?.revision == revision)
        #expect(projection?.project.projectionRevision == revision)
        #expect(projection?.project.recordedCount == counts(for: project).recorded)
        #expect(projection?.project.totalCount == project.totalCount)
        #expect(projection?.chapters.count == project.chapters.count)
        #expect(projection?.paragraphs.count == project.totalCount)
        let firstChapter = projection?.chapters[0]
        #expect(firstChapter?.paragraphCount == project.chapters[0].paragraphs.count)
        #expect(firstChapter?.recordedCount == project.chapters[0].paragraphs.count)
        #expect(firstChapter?.duration == project.chapters[0].paragraphs.reduce(0) { $0 + ($1.takes.first?.duration ?? 0) })
    }

    @Test func watchPinnedParagraphIDs_carriedThrough() {
        let project = makeProject()
        let pinned = project.allParagraphs.map(\.id)
        let projection = ProjectionBuilder().projection(
            from: project,
            counts: counts(for: project),
            revision: 1,
            watchPinnedParagraphIDs: pinned
        )
        #expect(projection?.watchPinnedParagraphIDs == pinned)
    }

    @Test func latestNote_isDenormalizedIntoProjection() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let paragraphID = ids.next()
        let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: "T", textHash: "h")
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "C", paragraphs: [paragraph])],
            createdAt: clock.now, modifiedAt: clock.now
        )
        let note = ReviewNote(
            id: ids.next(), paragraphID: paragraphID, text: "Pronounce softly", tag: .pronunciation, device: .watch
        )
        let projection = ProjectionBuilder().projection(
            from: project, counts: counts(for: project), revision: 0,
            latestNotes: [paragraphID: note]
        )
        #expect(projection?.paragraphs[0].latestNoteText == "Pronounce softly")
        #expect(projection?.paragraphs[0].latestNoteTag == .pronunciation)
    }
}
