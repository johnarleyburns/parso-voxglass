import Testing
import Foundation
@testable import VoxglassCore

@Suite struct GutenbergIndexTests {
    private func makeIndex() -> GutenbergCatalogIndex {
        GutenbergCatalogIndex(
            schema: 1,
            generatedAt: "2026-11-20T00:00:00Z",
            books: [
                GutenbergCatalogIndexBook(
                    id: 1,
                    title: "The Law",
                    authors: ["Doe, Jane"],
                    languages: ["en"],
                    subjects: ["Jurisprudence"],
                    bookshelves: ["Law"],
                    issued: "2000-01-01",
                    epub: "books/1/pg1.epub",
                    cover: "books/1/pg1.cover.medium.jpg"
                ),
                GutenbergCatalogIndexBook(
                    id: 2,
                    title: "American Law & Practice",
                    authors: ["Roe, Richard"],
                    languages: ["en"],
                    subjects: [],
                    bookshelves: ["Law"],
                    issued: "2001-01-01",
                    epub: "books/2/pg2.epub",
                    cover: "books/2/pg2.cover.medium.jpg"
                ),
                GutenbergCatalogIndexBook(
                    id: 3,
                    title: "Frankenstein",
                    authors: ["Shelley, Mary Wollstonecraft"],
                    languages: ["en"],
                    subjects: ["Science fiction"],
                    bookshelves: ["Gothic Fiction"],
                    issued: "1993-10-01",
                    epub: "books/3/pg3.epub",
                    cover: "books/3/pg3.cover.medium.jpg"
                )
            ]
        )
    }

    private let baseURL = URL(string: "https://gutenberg.parso.guru")!

    @Test func searchRanksTitleAndAuthorMatches() {
        let results = makeIndex().search("law", baseURL: baseURL)
        #expect(results.map(\.id) == [2, 1])
    }

    @Test func searchMatchesSubjectsAndShelves() {
        let results = makeIndex().search("gothic", baseURL: baseURL)
        #expect(results.map(\.id) == [3])
    }

    @Test func searchRequiresEveryToken() {
        let results = makeIndex().search("mary frankenstein", baseURL: baseURL)
        #expect(results.map(\.id) == [3])
    }

    @Test func resultUsesMirrorPaths() throws {
        let result = try #require(makeIndex().search("law", baseURL: baseURL).last)
        #expect(result.epubURL?.absoluteString == "https://gutenberg.parso.guru/gutenberg/books/1/pg1.epub")
        #expect(result.coverURL?.absoluteString == "https://gutenberg.parso.guru/gutenberg/books/1/pg1.cover.medium.jpg")
    }

    @Test func blankQueryReturnsNothing() {
        #expect(makeIndex().search("   ", baseURL: baseURL).isEmpty)
    }

    @Test @MainActor func storeLoadsACompressedIndexFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gutenberg-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoded = try JSONEncoder().encode(makeIndex())
        let compressed = try (encoded as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: directory.appendingPathComponent("index.json.zlib"))
        let manifest = GutenbergIndexManifest(
            schema: 1,
            version: "2026-11-20T00:00:00Z",
            index: "index.json.zlib",
            sha256: SHA256Hex.hex(compressed),
            bytes: compressed.count,
            bookCount: 3
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))

        let store = GutenbergIndexStore(baseURL: baseURL, storageDirectory: directory)
        await store.load()

        #expect(store.isAvailable)
        #expect(store.manifest?.bookCount == 3)
        let results = await store.search("law")
        #expect(results.map(\.id) == [2, 1])
    }
}
