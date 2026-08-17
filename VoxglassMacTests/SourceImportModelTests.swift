import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

@MainActor
@Suite struct SourceImportModelTests {

    @Test func modelInitialState() {
        let model = SourceImportModel()
        #expect(model.extractedDocument == nil)
        #expect(model.isLoading == false)
        #expect(model.error == nil)
        #expect(model.sourceDescription.isEmpty)
    }

    @Test func importPlainTextProducesDocument() async {
        let model = SourceImportModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test.txt")
        let content = "# Chapter One\n\nThis is the first paragraph.\n\nThis is the second paragraph."
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)

        let env = StudioEnvironment.test(seed: .empty)

        await model.importSource(from: fileURL, into: env)

        #expect(model.extractedDocument != nil)
        #expect(model.error == nil)
        #expect(model.isLoading == false)

        let doc = model.extractedDocument!
        #expect(doc.sections.count >= 1)
        #expect(doc.sections.first?.blocks.count ?? 0 >= 2)
    }

    @Test func importNonExistentFileReportsError() async {
        let model = SourceImportModel()
        let env = StudioEnvironment.test(seed: .empty)
        let nonexistentURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).txt")

        await model.importSource(from: nonexistentURL, into: env)

        #expect(model.extractedDocument == nil)
        #expect(model.error != nil)
        #expect(model.isLoading == false)
    }

    @Test func applyToProjectCreatesChaptersAndPersists() async throws {
        let model = SourceImportModel()
        let ids = UUIDGenerator()
        let clock = SystemClock()
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Book", author: "A", narrator: "N"),
            createdAt: clock.now,
            modifiedAt: clock.now
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SQLiteProductionStore(databaseURL: tempDir.appendingPathComponent("test.sqlite"))
        try await store.save(project)

        let env = StudioEnvironment.test(seed: .empty)
        env.store = store
        env.currentProject = project

        let block = ExtractedBlock(
            kind: .paragraph,
            text: "Hello world.",
            sourceRange: 0..<12
        )
        let section = ExtractedSection(
            heading: "Chapter 1",
            blocks: [block],
            sourceStart: 0
        )
        model.extractedDocument = ExtractedDocument(
            sections: [section],
            plainText: "Hello world."
        )

        await model.applyToProject(env)

        #expect(env.currentProject?.chapters.count == 1)
        #expect(env.currentProject?.chapters.first?.paragraphs.count == 1)
        #expect(env.currentProject?.chapters.first?.paragraphs.first?.text == "Hello world.")
        #expect(model.error == nil)

        let reloaded = try await store.load()
        #expect(reloaded.chapters.count == 1)
        #expect(reloaded.chapters.first?.paragraphs.first?.text == "Hello world.")
    }
}
