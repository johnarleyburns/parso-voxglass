import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

@MainActor
@Suite struct ScriptEditorModelTests {

    private func makeProject(with paragraph: Paragraph) -> AudiobookProject {
        let chapter = ProductionChapter(id: UUID(), ordinal: 0, title: "Ch 1", paragraphs: [paragraph])
        return AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [chapter]
        )
    }

    // MARK: - Debounce flush (§18.1.6)

    @Test func debounceFlushWritesExactlyOneUpdate() async throws {
        let store = SQLiteProductionStore(databaseURL: ProjectDatabase.makeTemporary(named: "script-debounce").url)
        let paragraph = Paragraph(id: UUID(), ordinal: 0, text: "Original text.", textHash: TextNormalizer.hash("Original text."))
        let project = makeProject(with: paragraph)
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 60)
        await model.load()

        // A typing burst: three keystrokes within the debounce window.
        model.updateText(paragraphID: paragraph.id, text: "Original text")
        model.updateText(paragraphID: paragraph.id, text: "Original")
        model.updateText(paragraphID: paragraph.id, text: "Original.")

        try await Task.sleep(for: .milliseconds(400))
        await model.flush()

        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first?.text == "Original.")
    }

    @Test func flushPersistsImmediately() async throws {
        let store = SQLiteProductionStore(databaseURL: ProjectDatabase.makeTemporary(named: "script-flush").url)
        let paragraph = Paragraph(id: UUID(), ordinal: 0, text: "Before", textHash: TextNormalizer.hash("Before"))
        let project = makeProject(with: paragraph)
        try await store.save(project)

        let model = ScriptEditorModel(store: store, project: project, debounceMilliseconds: 10_000)
        await model.load()

        model.updateText(paragraphID: paragraph.id, text: "After")
        await model.flush()

        let loaded = try await store.load()
        #expect(loaded.allParagraphs.first?.text == "After")
    }

    // MARK: - Drift banner (§9.5)

    @Test func driftBannerShowsForMinorAndSemanticNotNoneOrCosmetic() async throws {
        func makeParagraph(_ text: String) -> Paragraph {
            Paragraph(id: UUID(), ordinal: 0, text: text, textHash: TextNormalizer.hash(text))
        }

        // .none — identical text.
        let none = makeParagraph("The quick brown fox.")
        let noneTake = Take(
            id: UUID(), paragraphID: none.id,
            assetRef: AudioAssetReference(sha256: "a", relativePath: "a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: none.textHash
        )
        var nonePara = none
        nonePara.takes = [noneTake]
        nonePara.selectedTakeID = noneTake.id
        let noneProject = makeProject(with: nonePara)
        let noneModel = ScriptEditorModel(store: InMemoryProductionStore(), project: noneProject, debounceMilliseconds: 10_000)
        #expect(noneModel.driftKind(for: nonePara.id) == .none)

        // .cosmetic — only punctuation differs.
        let recorded = "The quick brown fox."
        let cosmeticCurrent = "The quick brown fox!"
        let cosmetic = makeParagraph(cosmeticCurrent)
        let cosmeticTake = Take(
            id: UUID(), paragraphID: cosmetic.id,
            assetRef: AudioAssetReference(sha256: "b", relativePath: "b.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: TextNormalizer.hash(recorded)
        )
        var cosmeticPara = cosmetic
        cosmeticPara.takes = [cosmeticTake]
        cosmeticPara.selectedTakeID = cosmeticTake.id
        let cosmeticModel = ScriptEditorModel(store: InMemoryProductionStore(), project: makeProject(with: cosmeticPara), debounceMilliseconds: 10_000)
        cosmeticModel.recordedTexts[cosmeticPara.id] = recorded
        #expect(cosmeticModel.driftKind(for: cosmeticPara.id) == .cosmetic)

        // .minor — a single word edit in a longer text (≤ 5% of tokens).
        let minorRecorded = "The quick brown fox jumps over the lazy dog beside the river and through the trees in the meadow while the sun was setting gently over the distant hills"
        let minorCurrent = "The quick brown fox jumps over the lazy dog beside the river and through the trees in the fields while the sun was setting gently over the distant hills"
        let minor = makeParagraph(minorCurrent)
        let minorTake = Take(
            id: UUID(), paragraphID: minor.id,
            assetRef: AudioAssetReference(sha256: "c", relativePath: "c.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: TextNormalizer.hash(minorRecorded)
        )
        var minorPara = minor
        minorPara.takes = [minorTake]
        minorPara.selectedTakeID = minorTake.id
        let minorModel = ScriptEditorModel(store: InMemoryProductionStore(), project: makeProject(with: minorPara), debounceMilliseconds: 10_000)
        minorModel.recordedTexts[minorPara.id] = minorRecorded
        #expect(minorModel.driftKind(for: minorPara.id) == .minor)

        // .semantic — a number changed.
        let semanticCurrent = "Chapter 4"
        let semantic = makeParagraph(semanticCurrent)
        let semanticTake = Take(
            id: UUID(), paragraphID: semantic.id,
            assetRef: AudioAssetReference(sha256: "d", relativePath: "d.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: TextNormalizer.hash("Chapter 3")
        )
        var semanticPara = semantic
        semanticPara.takes = [semanticTake]
        semanticPara.selectedTakeID = semanticTake.id
        let semanticModel = ScriptEditorModel(store: InMemoryProductionStore(), project: makeProject(with: semanticPara), debounceMilliseconds: 10_000)
        semanticModel.recordedTexts[semanticPara.id] = "Chapter 3"
        #expect(semanticModel.driftKind(for: semanticPara.id) == .semantic)
    }

    // MARK: - Generated paragraphs (mockup `05`)

    @Test func generatedParagraphsAreReadOnlyByDefault() {
        let intro = Paragraph(id: UUID(), ordinal: 0, text: "This is a LibriVox recording…", textHash: TextNormalizer.hash("This is a LibriVox recording…"), role: .libriVoxIntro)
        let body = Paragraph(id: UUID(), ordinal: 1, text: "Chapter one.", textHash: TextNormalizer.hash("Chapter one."), role: .body)
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "Ch", paragraphs: [intro, body])]
        )
        let model = ScriptEditorModel(store: InMemoryProductionStore(), project: project)

        #expect(model.isGenerated(intro.id))
        #expect(!model.isEditable(intro.id))
        #expect(model.isEditable(body.id))

        model.confirmEditAnyway(intro.id)
        #expect(model.isEditable(intro.id))
    }
}
