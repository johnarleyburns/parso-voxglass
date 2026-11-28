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

// Serialized: the static URLProtocol below records process-wide request state.
@Suite(.serialized)
struct GutenbergIndexRefreshTests {
    final class MockMirrorServer: URLProtocol {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var manifest: Data?
            var index: Data?
            var requests: [String] = []
            var delay: TimeInterval = 0
        }
        private static let state = State()

        static func reset(manifest: Data?, index: Data?, delay: TimeInterval = 0) {
            state.lock.lock()
            state.manifest = manifest
            state.index = index
            state.requests = []
            state.delay = delay
            state.lock.unlock()
        }

        static var requests: [String] {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.requests
        }

        static var manifestRequests: Int {
            requests.filter { $0 == "manifest.json" }.count
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let name = request.url?.lastPathComponent ?? ""
            Self.state.lock.lock()
            Self.state.requests.append(name)
            let manifest = Self.state.manifest
            let index = Self.state.index
            let delay = Self.state.delay
            Self.state.lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard let payload = name == "manifest.json" ? manifest : index else {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private let baseURL = URL(string: "https://mirror.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMirrorServer.self]
        return URLSession(configuration: configuration)
    }

    private func index(id: Int = 1, title: String = "The Law") -> GutenbergCatalogIndex {
        GutenbergCatalogIndex(
            schema: 1,
            generatedAt: "2026-11-20T00:00:00Z",
            books: [
                GutenbergCatalogIndexBook(
                    id: id,
                    title: title,
                    authors: ["Doe, Jane"],
                    languages: ["en"],
                    subjects: ["Jurisprudence"],
                    bookshelves: ["Law"],
                    issued: "2000-01-01",
                    epub: "books/\(id)/pg\(id).epub",
                    cover: "books/\(id)/pg\(id).cover.medium.jpg"
                )
            ]
        )
    }

    private func compressed(_ index: GutenbergCatalogIndex) throws -> Data {
        let encoded = try JSONEncoder().encode(index)
        return try (encoded as NSData).compressed(using: .zlib) as Data
    }

    private func manifest(
        indexName: String,
        compressed: Data,
        sha256: String? = nil,
        bytes: Int? = nil,
        bookCount: Int = 1
    ) throws -> Data {
        try JSONEncoder().encode(GutenbergIndexManifest(
            schema: 1,
            version: "2026-11-20T00:00:00Z",
            index: indexName,
            sha256: sha256 ?? SHA256Hex.hex(compressed),
            bytes: bytes ?? compressed.count,
            bookCount: bookCount
        ))
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gutenberg-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test @MainActor func loadRejectsACompressedIndexThatDoesNotMatchItsManifest() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = try compressed(index())
        let manifest = try manifest(
            indexName: "index.json.zlib",
            compressed: payload,
            sha256: String(repeating: "0", count: 64)
        )
        try payload.write(to: directory.appendingPathComponent("index.json.zlib"))
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))

        let store = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )
        await store.load()

        #expect(!store.isAvailable)
        #expect(store.lastRefreshError != nil)
    }

    @Test @MainActor func prepareForSearchLoadsTheMirrorBeforeFallback() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = try compressed(index())
        MockMirrorServer.reset(
            manifest: try manifest(indexName: "index-abc.json.zlib", compressed: payload),
            index: payload
        )
        let store = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )

        await store.prepareForSearch()

        #expect(store.isAvailable)
        #expect(MockMirrorServer.requests == ["manifest.json", "index-abc.json.zlib"])
        let results = await store.search("law")
        #expect(results.first?.epubURL?.absoluteString == "https://mirror.test/gutenberg/books/1/pg1.epub")
        #expect(results.first?.coverURL?.absoluteString
            == "https://mirror.test/gutenberg/books/1/pg1.cover.medium.jpg")
    }

    @Test @MainActor func prepareForSearchUsesAValidCacheWithoutWaitingForTheNetwork() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = try compressed(index())
        try payload.write(to: directory.appendingPathComponent("index.json.zlib"))
        try manifest(indexName: "index.json.zlib", compressed: payload)
            .write(to: directory.appendingPathComponent("manifest.json"))
        MockMirrorServer.reset(manifest: nil, index: nil)

        let store = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )
        await store.prepareForSearch()

        #expect(store.isAvailable)
        #expect(MockMirrorServer.requests.isEmpty)
    }

    @Test @MainActor func concurrentColdStartRefreshesShareOneManifestDownload() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = try compressed(index())
        MockMirrorServer.reset(
            manifest: try manifest(indexName: "index-abc.json.zlib", compressed: payload),
            index: payload,
            delay: 0.2
        )
        let store = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )

        let first = Task { @MainActor in await store.refreshIfNeeded() }
        let second = Task { @MainActor in await store.refreshIfNeeded() }
        await first.value
        await second.value

        #expect(MockMirrorServer.manifestRequests == 1)
        #expect(store.isAvailable)
    }

    @Test @MainActor func failedRemoteChecksumKeepsThePreviousIndexAndFiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try compressed(index())
        try original.write(to: directory.appendingPathComponent("index.json.zlib"))
        try manifest(indexName: "index.json.zlib", compressed: original)
            .write(to: directory.appendingPathComponent("manifest.json"))

        let store = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )
        await store.load()
        #expect(store.isAvailable)

        let replacement = try compressed(index(id: 2, title: "Replacement"))
        MockMirrorServer.reset(
            manifest: try manifest(
                indexName: "index-bad.json.zlib",
                compressed: replacement,
                sha256: String(repeating: "f", count: 64)
            ),
            index: replacement
        )

        await store.refreshIfNeeded()

        #expect(store.index?.books.first?.id == 1)
        #expect(store.manifest?.index == "index.json.zlib")
        #expect(store.lastRefreshError != nil)

        let reloaded = GutenbergIndexStore(
            baseURL: baseURL,
            session: session(),
            storageDirectory: directory
        )
        await reloaded.load()
        #expect(reloaded.index?.books.first?.id == 1)
    }

    @Test func discoverPreparesTheMirrorBeforeUsingTheLegacyFallback() throws {
        let text = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let prepare = try #require(text.range(of: "await gutenbergIndex.prepareForSearch()"))
        let fallback = try #require(text.range(of: "GutenbergCatalogClient().search"))
        #expect(prepare.lowerBound < fallback.lowerBound)
        #expect(text.contains("await indexStore.refreshIfNeeded()"))
    }

    private func source(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
