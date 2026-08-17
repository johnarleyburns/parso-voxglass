import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// §8.4 undo table: edit text, split, merge, select take, archive take,
/// reorder chapters all round-trip; recording is never undoable.
@MainActor
@Suite struct UndoTests {

    private func makeParagraph(_ id: UUID, _ text: String, role: ParagraphRole = .body) -> Paragraph {
        Paragraph(id: id, ordinal: 0, text: text, textHash: TextNormalizer.hash(text), role: role)
    }

    @Test func editTextUndoRestoresPreviousTextAndHash() async throws {
        let store = InMemoryProductionStore()
        let para = makeParagraph(UUID(), "Original text.")
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [para])]
        )
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 10_000)
        await model.load()

        model.updateText(paragraphID: para.id, text: "Changed text.")
        await model.flush()
        #expect(try await store.load().allParagraphs.first?.text == "Changed text.")

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        let restored = try await store.load()
        #expect(restored.allParagraphs.first?.text == "Original text.")
        #expect(restored.allParagraphs.first?.textHash == para.textHash)
    }

    @Test func splitUndoRestoresExactParagraph() async throws {
        let store = InMemoryProductionStore()
        let para = makeParagraph(UUID(), "First half. Second half.")
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [para])]
        )
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 10_000)
        await model.load()

        await model.split(paragraphID: para.id, atCharacterOffset: 11)
        var after = try await store.load()
        #expect(after.allParagraphs.count == 2)
        #expect(after.allParagraphs.contains(where: { $0.id == para.id }))
        let secondID = after.allParagraphs.first { $0.id != para.id }?.id

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        after = try await store.load()
        #expect(after.allParagraphs.count == 1)
        #expect(after.allParagraphs.first?.id == para.id)
        #expect(after.allParagraphs.first?.text == "First half. Second half.")
        #expect(secondID != nil)
    }

    @Test func mergeUndoRestoresBothParagraphs() async throws {
        let store = InMemoryProductionStore()
        let first = makeParagraph(UUID(), "First half.")
        var second = makeParagraph(UUID(), "Second half.")
        second.ordinal = 1
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [first, second])]
        )
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 10_000)
        await model.load()

        await model.merge(paragraphID: first.id)
        var after = try await store.load()
        #expect(after.allParagraphs.count == 1)
        #expect(after.allParagraphs.first?.id == first.id)
        #expect(after.allParagraphs.first?.text.contains("First half.") == true)
        #expect(after.allParagraphs.first?.text.contains("Second half.") == true)

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        after = try await store.load()
        #expect(after.allParagraphs.count == 2)
        #expect(Set(after.allParagraphs.map(\.id)) == Set([first.id, second.id]))
    }

    @Test func selectTakeUndoRestoresPreviousSelection() async throws {
        let store = InMemoryProductionStore()
        let para = makeParagraph(UUID(), "Text.")
        let takeA = Take(
            id: UUID(), paragraphID: para.id,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        let takeB = Take(
            id: UUID(), paragraphID: para.id,
            assetRef: AudioAssetReference(sha256: "b", relativePath: "b.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        var paraWithTakes = para
        paraWithTakes.takes = [takeA, takeB]
        paraWithTakes.selectedTakeID = takeA.id
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [paraWithTakes])]
        )
        try await store.save(project)

        let model = RecordingModel(
            capture: FakeAudioCapture(),
            store: store,
            assets: InMemoryAssetStore(),
            projectID: project.id
        )
        await model.loadProject()
        await model.loadParagraph(para.id)
        #expect(model.selectedTakeID == takeA.id)

        await model.selectTake(takeB.id)
        #expect(model.selectedTakeID == takeB.id)

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        let restored = try await store.load()
        #expect(restored.allParagraphs.first?.selectedTakeID == takeA.id)
    }

    @Test func archiveTakeUndoUnarchives() async throws {
        let store = InMemoryProductionStore()
        let para = makeParagraph(UUID(), "Text.")
        let take = Take(
            id: UUID(), paragraphID: para.id,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        var paraWithTake = para
        paraWithTake.takes = [take]
        paraWithTake.selectedTakeID = take.id
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [paraWithTake])]
        )
        try await store.save(project)

        let model = RecordingModel(
            capture: FakeAudioCapture(),
            store: store,
            assets: InMemoryAssetStore(),
            projectID: project.id
        )
        await model.loadProject()
        await model.loadParagraph(para.id)

        await model.archiveCurrentTake()
        var stored = try await store.load()
        #expect(stored.allParagraphs.first?.takes.first?.isArchived == true)

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        stored = try await store.load()
        #expect(stored.allParagraphs.first?.takes.first?.isArchived == false)
    }

    @Test func reorderChaptersUndoRestoresPriorOrdinals() async throws {
        let store = InMemoryProductionStore()
        let chA = ProductionChapter(id: UUID(), ordinal: 0, title: "A", paragraphs: [makeParagraph(UUID(), "A text")])
        let chB = ProductionChapter(id: UUID(), ordinal: 1, title: "B", paragraphs: [makeParagraph(UUID(), "B text")])
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [chA, chB]
        )
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 10_000)
        await model.load()

        await model.moveChapter(chB.id, to: 0)
        var after = try await store.load()
        #expect(after.chapters.map(\.ordinal) == [0, 1])
        #expect(after.chapters.first?.id == chB.id)

        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        after = try await store.load()
        #expect(after.chapters.first?.id == chA.id)
        #expect(after.chapters.map(\.id) == [chA.id, chB.id])
    }

    @Test func recordingIsNeverUndoable() async throws {
        let store = InMemoryProductionStore()
        let para = makeParagraph(UUID(), "Text.")
        let existingTake = Take(
            id: UUID(), paragraphID: para.id,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
        var paraWithTake = para
        paraWithTake.takes = [existingTake]
        paraWithTake.selectedTakeID = existingTake.id
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [paraWithTake])]
        )
        try await store.save(project)

        let capture = FakeAudioCapture()
        let assets = InMemoryAssetStore()
        let model = RecordingModel(capture: capture, store: store, assets: assets, projectID: project.id)
        await model.loadProject()
        await model.loadParagraph(para.id)
        await model.prepare()

        let takeCountBefore = try await store.load().allParagraphs.first?.takes.count ?? 0
        await model.startRecording(paragraphID: para.id)
        await model.stopRecording()

        var after = try await store.load()
        #expect(after.allParagraphs.first?.takes.count == takeCountBefore + 1)
        let newTakeID = model.takes.last?.id

        // Undo after record must NOT destroy the take — only reselect the
        // previous take (which was already selected here, so nothing moves).
        model.undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        after = try await store.load()
        #expect(after.allParagraphs.first?.takes.count == takeCountBefore + 1, "undo after record must destroy nothing")
        #expect(after.allParagraphs.flatMap(\.takes).contains(where: { $0.id == newTakeID }), "the recorded take must survive undo")
    }
}
