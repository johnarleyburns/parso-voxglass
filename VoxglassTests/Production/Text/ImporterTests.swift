import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassCore

@Suite struct TXTImporterTests {

    @Test func importSimpleTXT() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_txt_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "Chapter 1\n\nThis is the first paragraph.\n\nThis is the second paragraph.".write(to: tmp, atomically: true, encoding: .utf8)

        let importer = TXTImporter()
        #expect(importer.canImport(tmp))

        let doc = try await importer.extract(from: tmp)
        #expect(doc.sections.count == 1)
        #expect(doc.sections[0].blocks.count >= 2)
    }

    @Test func detectHeadings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_heading_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "CHAPTER 1\n\nThe beginning of the story.".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await TXTImporter().extract(from: tmp)
        let headings = doc.sections[0].blocks.filter { $0.kind == .heading }
        #expect(headings.count >= 1)
    }

    @Test func detectSceneBreaks() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_scene_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "Scene one.\n\n* * *\n\nScene two.".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await TXTImporter().extract(from: tmp)
        #expect(doc.warnings.contains { $0.kind == .possibleSceneBreak })
    }

    @Test func uppercaseHeadingDetection() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_upper_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "THE GREAT ADVENTURE\n\nIt was a dark and stormy night.".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await TXTImporter().extract(from: tmp)
        #expect(doc.sections[0].blocks.first?.kind == .heading)
    }
}

@Suite struct MarkdownImporterTests {

    @Test func importSimpleMD() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_md_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "# Chapter One\n\nThis is a paragraph.\n\n## Section Two\n\nMore text here.".write(to: tmp, atomically: true, encoding: .utf8)

        let importer = MarkdownImporter()
        #expect(importer.canImport(tmp))

        let doc = try await importer.extract(from: tmp)
        #expect(doc.sections.count >= 2)
    }

    @Test func stripsInlineMarkup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_strip_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "# Title\n\nSome **bold** and *italic* text with [a link](http://example.com).".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await MarkdownImporter().extract(from: tmp)
        let blocks = doc.sections.flatMap(\.blocks)
        let text = blocks.map(\.text).joined(separator: " ")
        #expect(!text.contains("**"))
        #expect(!text.contains("["))
    }

    @Test func thematicBreakDetected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_break_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "# Part One\n\nSome text.\n\n***\n\nMore text after break.".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await MarkdownImporter().extract(from: tmp)
        #expect(doc.sections.flatMap(\.blocks).contains { $0.kind == .sceneBreak })
    }

    @Test func frontMatterParsed() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_fm_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
        ---
        title: My Book
        author: John Doe
        language: en
        ---

        # Chapter One

        Beginning text.
        """.write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await MarkdownImporter().extract(from: tmp)
        #expect(doc.title == "My Book")
        #expect(doc.author == "John Doe")
        #expect(doc.language == "en")
    }

    @Test func blockquoteDetected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_bq_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "# Chapter\n\n> This is a quote.\n\nNormal text.".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await MarkdownImporter().extract(from: tmp)
        #expect(doc.sections.flatMap(\.blocks).contains { $0.kind == .blockquote })
    }

    @Test func importEmptyMarkdown() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_empty_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "".write(to: tmp, atomically: true, encoding: .utf8)

        let doc = try await MarkdownImporter().extract(from: tmp)
        #expect(doc.sections.count <= 1)
    }
}

@Suite struct EPUBImporterTests {

    @Test func extractsSpineItemsWithKnownShape() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ImportFixtures.makeEPUB(in: dir)
        let importer = EPUBImporter()
        #expect(importer.canImport(url))

        let doc = try await importer.extract(from: url)
        // One section per spine item.
        #expect(doc.sections.count == 2)
        #expect(doc.title == "The EPUB Fixture")
        #expect(doc.author == "Fixture Author")

        // First spine item opens with a heading → chapter title.
        let firstSection = doc.sections[0]
        #expect(firstSection.heading == "Chapter One")
        #expect(firstSection.blocks.contains { $0.kind == .heading && $0.headingLevel == 1 })
        #expect(firstSection.blocks.filter { $0.kind == .paragraph }.count == 2)
    }

    @Test func malformedEPUBFallsBackWithoutThrowing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A ZIP that is not an EPUB (no container.xml).
        let url = dir.appendingPathComponent("not-an-epub.epub")
        try TestZipWriter.write(entries: [("hello.txt", Data("hi".utf8))], to: url)

        let doc = try await EPUBImporter().extract(from: url)
        #expect(doc.sections.isEmpty)
        #expect(!doc.warnings.isEmpty)
    }

    @Test func progressiveParseYieldsPreviewBeforeCompletion() async throws {
        // §8.2: the progressive stream must expose chapter structure before the
        // parse finishes, and its completed result must match the synchronous
        // `extract`.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-prog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ImportFixtures.makeEPUB(in: dir)
        let importer = EPUBImporter()
        let expected = try await importer.extract(from: url)

        var updates: [ProgressiveImportUpdate] = []
        let stream = try await importer.extractProgressively(from: url)
        for try await update in stream {
            updates.append(update)
        }

        // The fixture has two spine items: at least one intermediate preview
        // update is yielded before the final complete one.
        #expect(updates.count >= 2)
        #expect(updates.dropLast().allSatisfy { !$0.isComplete })
        #expect(updates.last?.isComplete == true)

        let final = try #require(updates.last?.completedDocument)
        #expect(final.sections.count == expected.sections.count)
        #expect(final.title == expected.title)
        #expect(final.author == expected.author)
        #expect(final.plainText == expected.plainText)
    }
}

@Suite struct DOCXImporterTests {

    @Test func extractsHeadingAndParagraphs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ImportFixtures.makeDOCX(in: dir)
        let importer = DOCXImporter()
        #expect(importer.canImport(url))

        let doc = try await importer.extract(from: url)
        let blocks = doc.sections.flatMap(\.blocks)
        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .heading)
        #expect(blocks[0].text == "Chapter One")
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[1].text.contains("first paragraph"))
        #expect(blocks[2].kind == .paragraph)
    }

    @Test func missingDocumentThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("broken.docx")
        try TestZipWriter.write(entries: [("nope.txt", Data("x".utf8))], to: url)

        await #expect(throws: ImportError.self) {
            _ = try await DOCXImporter().extract(from: url)
        }
    }
}
