import Foundation
import VoxglassCore

enum ReadWithAIImporter {
    enum ImportError: LocalizedError {
        case noReadableText

        var errorDescription: String? {
            switch self {
            case .noReadableText: "This document did not contain readable text."
            }
        }
    }

    /// Parses an EPUB with the existing hardened importer, then writes one
    /// app-owned UTF-8 asset per semantic section.  A chapter asset is the
    /// playback unit for AVSpeechSynthesizer and keeps the library schema
    /// identical to every other book source.
    static func prepare(
        documentURL: URL,
        sourceTitle: String,
        sourceURL: URL? = nil,
        stableIdentifier: String? = nil,
        titleOverride: String? = nil,
        authorsOverride: [String]? = nil,
        isPending: Bool = false
    ) async throws -> ReadWithAIImport {
        let document: ExtractedDocument
        switch documentURL.pathExtension.lowercased() {
        case "epub": document = try await EPUBImporter().extract(from: documentURL)
        case "pdf": document = try await PDFImporter().extract(from: documentURL)
        default: throw ImportError.noReadableText
        }
        let root = try makeBookDirectory()
        var chapters: [ReadWithAIChapterImport] = []

        for (index, section) in document.sections.enumerated() {
            let text = section.blocks.map(\.text)
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let url = root.appendingPathComponent(String(format: "chapter-%05d.voxtext", index))
            try text.write(to: url, atomically: true, encoding: .utf8)
            chapters.append(ReadWithAIChapterImport(
                title: section.heading?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? "Chapter \(chapters.count + 1)",
                textURL: url
            ))
        }

        // Some valid EPUBs expose all prose in a single spine item with no
        // headings. The importer still gives us `plainText`; retain it as one
        // playable chapter rather than rejecting the book.
        if chapters.isEmpty {
            let text = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ImportError.noReadableText }
            let url = root.appendingPathComponent("chapter-00000.voxtext")
            try text.write(to: url, atomically: true, encoding: .utf8)
            chapters = [ReadWithAIChapterImport(title: "Book", textURL: url)]
        }

        return ReadWithAIImport(
            title: titleOverride?.nonEmpty ?? document.title?.nonEmpty ?? documentURL.deletingPathExtension().lastPathComponent,
            authors: authorsOverride?.filter { $0.nonEmpty != nil } ?? document.author.map { [$0] } ?? [],
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            stableIdentifier: stableIdentifier,
            isPending: isPending,
            chapters: chapters
        )
    }

    static func downloadAndPrepare(
        epubURL: URL,
        sourceTitle: String,
        sourceURL: URL?,
        stableIdentifier: String,
        title: String,
        authors: [String],
        isPending: Bool = true
    ) async throws -> ReadWithAIImport {
        let (data, response) = try await URLSession.shared.data(from: epubURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let file = try makeBookDirectory().appendingPathComponent("source.epub")
        try data.write(to: file, options: .atomic)
        return try await prepare(documentURL: file, sourceTitle: sourceTitle, sourceURL: sourceURL,
                                 stableIdentifier: stableIdentifier, titleOverride: title, authorsOverride: authors,
                                 isPending: isPending)
    }

    private static func makeBookDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("ReadWithAI", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
