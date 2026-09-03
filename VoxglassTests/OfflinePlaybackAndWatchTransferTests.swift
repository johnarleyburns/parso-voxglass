import Foundation
import Testing
import ParsoAudioStreaming
import VoxglassCoreTestSupport
@testable import VoxglassCore

// MARK: - INV-B: one canonical audio identity per chapter (Fix 3)

@Suite struct ChapterAudioIdentityTests {
    private let bookID = UUID()

    @Test func canonicalURLMatchesPlayableURL() {
        let remote = URL(string: "https://archive.org/download/item/ch1.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1, remoteURL: remote)
        #expect(ChapterAudioIdentity.canonicalURL(for: chapter) == chapter.resolvedPlayableURL())
    }

    @Test func phoneDownloadKeyMatchesWatchStoreKeyWithOpus() throws {
        // A chapter with both renditions: the phone downloader, the phone→watch
        // transfer, and the watch store must all key on the SAME identity.
        let opus = URL(string: "https://archive.org/download/item/ch1.opus")!
        let remote = URL(string: "https://archive.org/download/item/ch1.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1, remoteURL: remote, opusURL: opus)

        let phoneDownloadKey = try #require(ChapterAudioIdentity.cacheKey(for: chapter))
        let phoneTransferKey = try #require(ChapterAudioIdentity.cacheKey(for: chapter))
        let watchStoreKey = try #require(WatchChapterCache.key(for: chapter))

        #expect(phoneDownloadKey == phoneTransferKey)
        #expect(phoneDownloadKey == watchStoreKey)
        #expect(phoneDownloadKey == AudioCache.key(for: remote))
    }

    @Test func phoneDownloadKeyMatchesWatchStoreKeyWithoutOpus() throws {
        let remote = URL(string: "https://archive.org/download/item/ch2.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 2, remoteURL: remote)

        let phoneDownloadKey = try #require(ChapterAudioIdentity.cacheKey(for: chapter))
        let phoneTransferKey = try #require(ChapterAudioIdentity.cacheKey(for: chapter))
        let watchStoreKey = try #require(WatchChapterCache.key(for: chapter))

        #expect(phoneDownloadKey == phoneTransferKey)
        #expect(phoneDownloadKey == watchStoreKey)
    }

    @Test func noURLsYieldsNilIdentity() {
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1)
        #expect(ChapterAudioIdentity.canonicalURL(for: chapter) == nil)
        #expect(ChapterAudioIdentity.cacheKey(for: chapter) == nil)
        #expect(WatchChapterCache.key(for: chapter) == nil)
    }
}

// MARK: - INV-A: pinned offline blobs live in the durable root

/// The store-mechanics of the durable tier (pin/unpin moves the blob between
/// roots, survives a reload, `remove` clears both, streaming budget excludes it)
/// are owned by `parso-audio-engine`'s `SparseCacheStoreTests`. Here we only
/// assert Voxglass's use of it: a downloaded chapter is durable and resolvable
/// after a relaunch.
@Suite struct StreamCacheOfflineRootTests {
    private let directory: URL
    private let store: SparseCacheStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-offline-tests-\(UUID().uuidString)", isDirectory: true)
        store = SparseCacheStore(directory: directory)
    }

    @Test func ingestedChapterIsDurableAndExcludedFromTheStreamingBudget() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 50).write(to: source)
        await store.ingestCompleteFile(at: source, key: "pinned_key", totalBytes: 50)

        #expect(await store.isDurable("pinned_key"))
        #expect(await store.isComplete("pinned_key"))
        #expect(await store.totalCachedBytes() == 0)   // durable bytes are off-budget
    }

    @Test func durableChapterSurvivesAReopen() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 5, count: 40).write(to: source)
        await store.ingestCompleteFile(at: source, key: "durable_key", totalBytes: 40)

        let reopened = SparseCacheStore(directory: directory)
        #expect(await reopened.isComplete("durable_key"))
        #expect(await reopened.isDurable("durable_key"))
        #expect(FileManager.default.fileExists(atPath: await reopened.fileURL(for: "durable_key").path))
    }

    @Test func removingADurableChapterClearsItsBlob() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 25).write(to: source)
        await store.ingestCompleteFile(at: source, key: "remove_offline", totalBytes: 25)
        let blob = await store.fileURL(for: "remove_offline")

        await store.remove(keys: ["remove_offline"])

        #expect(!(await store.contains("remove_offline")))
        #expect(!FileManager.default.fileExists(atPath: blob.path))
    }
}

// MARK: - Fix 2: phone→watch transfer resolves through the store

@Suite struct WatchChapterTransferTests {
    private let directory: URL
    private let store: SparseCacheStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        store = SparseCacheStore(directory: directory)
    }

    @Test func absentBlobReturnsNilWithoutNetwork() async {
        let url = await WatchChapterTransfer.resolvedFileURL(cacheStore: store, chapterKey: "nope")
        #expect(url == nil)
    }

    @Test func incompleteBlobReturnsNilWithoutNetwork() async {
        await store.setContentLength(100, for: "partial")
        await store.recordWrite(range: 0..<50, for: "partial")
        let url = await WatchChapterTransfer.resolvedFileURL(cacheStore: store, chapterKey: "partial")
        #expect(url == nil)
    }

    @Test func completeBlobResolvesToAReadableURL() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 8, count: 200).write(to: source)
        await store.ingestCompleteFile(at: source, key: "complete_chapter", totalBytes: 200)

        let url = await WatchChapterTransfer.resolvedFileURL(cacheStore: store, chapterKey: "complete_chapter")
        let resolved = try #require(url)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(try Data(contentsOf: resolved).count == 200)
    }
}
