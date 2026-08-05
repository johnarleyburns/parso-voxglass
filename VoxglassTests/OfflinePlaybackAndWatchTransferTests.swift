import Foundation
import Testing
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
        #expect(phoneDownloadKey == StreamCacheUtils.key(for: remote))
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

// MARK: - INV-A: pinned offline blobs live in the durable root (Fix 1)

@Suite struct StreamCacheOfflineRootTests {
    private var directory: URL!
    private var store: StreamCacheStore!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-offline-tests-\(UUID().uuidString)", isDirectory: true)
        store = StreamCacheStore(directory: directory)
    }

    private var streamingRoot: URL {
        directory.appendingPathComponent("StreamCache", isDirectory: true)
    }

    private var offlineRoot: URL {
        directory.appendingPathComponent("OfflineAudio", isDirectory: true)
    }

    private var streamingMetaRoot: URL {
        directory.appendingPathComponent("StreamCacheMeta", isDirectory: true)
    }

    private var offlineMetaRoot: URL {
        directory.appendingPathComponent("OfflineMeta", isDirectory: true)
    }

    @Test func unpinnedKeyResolvesToStreamingRoot() async {
        await store.setContentLength(100, for: "streaming_key")
        let url = await store.fileURL(for: "streaming_key")
        #expect(url.deletingLastPathComponent().path == streamingRoot.path)
    }

    @Test func pinnedKeyResolvesToOfflineRoot() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 50).write(to: source)
        await store.ingestCompleteFile(at: source, key: "pinned_key", totalBytes: 50)

        let url = await store.fileURL(for: "pinned_key")
        #expect(url.deletingLastPathComponent().path == offlineRoot.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(
            atPath: streamingRoot.appendingPathComponent("pinned_key").path
        ))
    }

    @Test func pinMovesBlobAndMetaIntoOfflineRoot() async throws {
        // Seed a passive-cache entry in the streaming root.
        let streamingURL = await store.fileURL(for: "moved_key")
        try Data(repeating: 2, count: 100).write(to: streamingURL)
        await store.setContentLength(100, for: "moved_key")
        await store.recordWrite(range: 0..<100, for: "moved_key")

        await store.pin(["moved_key"])

        let offlineURL = await store.fileURL(for: "moved_key")
        #expect(offlineURL.deletingLastPathComponent().path == offlineRoot.path)
        #expect(FileManager.default.fileExists(atPath: offlineURL.path))
        #expect(!FileManager.default.fileExists(atPath: streamingURL.path))
        #expect(try Data(contentsOf: offlineURL).count == 100)
        // The meta file moved alongside the blob.
        #expect(FileManager.default.fileExists(
            atPath: offlineMetaRoot.appendingPathComponent("moved_key.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: streamingMetaRoot.appendingPathComponent("moved_key.json").path
        ))
        #expect(await store.isPinned("moved_key"))
    }

    @Test func unpinMovesBlobAndMetaBackToStreamingRoot() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 3, count: 80).write(to: source)
        await store.ingestCompleteFile(at: source, key: "revert_key", totalBytes: 80)

        await store.unpin(["revert_key"])

        let url = await store.fileURL(for: "revert_key")
        #expect(url.deletingLastPathComponent().path == streamingRoot.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).count == 80)
        #expect(!FileManager.default.fileExists(
            atPath: offlineRoot.appendingPathComponent("revert_key").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: streamingMetaRoot.appendingPathComponent("revert_key.json").path
        ))
        #expect(!(await store.isPinned("revert_key")))
    }

    @Test func migrationRelocatesExistingPinsAndDropsMissingBlobs() async throws {
        // Simulate the legacy pre-migration layout: pins file in the legacy
        // location, blobs in the streaming root, one pin whose blob was purged.
        let legacyPinsURL = directory.appendingPathComponent("LegacyPins.json")

        let presentBlob = streamingRoot.appendingPathComponent("legacy_present")
        try Data(repeating: 4, count: 60).write(to: presentBlob)
        let presentMeta = streamingMetaRoot.appendingPathComponent("legacy_present.json")
        try Data("{\"cachedBytes\":60,\"complete\":true}".utf8).write(to: presentMeta)

        let legacyPins = ["legacy_present", "legacy_purged"]
        try JSONEncoder().encode(legacyPins).write(to: legacyPinsURL)

        let dropped = await store.migrateLegacyPinnedBlobs(legacyPinsURL: legacyPinsURL)

        #expect(dropped == ["legacy_purged"])
        #expect(await store.isPinned("legacy_present"))
        #expect(!(await store.isPinned("legacy_purged")))
        // The surviving blob + meta moved into the offline root.
        #expect(FileManager.default.fileExists(
            atPath: offlineRoot.appendingPathComponent("legacy_present").path
        ))
        #expect(!FileManager.default.fileExists(atPath: presentBlob.path))
        #expect(FileManager.default.fileExists(
            atPath: offlineMetaRoot.appendingPathComponent("legacy_present.json").path
        ))
        // The dropped pin's meta is gone and the legacy pins file is removed.
        #expect(!FileManager.default.fileExists(atPath: presentMeta.path))
        #expect(!FileManager.default.fileExists(atPath: legacyPinsURL.path))
        // Pins persist at the new location for the next launch.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("OfflinePins.json").path
        ))
    }

    @Test func migrationWithoutLegacyPinsIsNoop() async {
        let dropped = await store.migrateLegacyPinnedBlobs(
            legacyPinsURL: directory.appendingPathComponent("MissingPins.json")
        )
        #expect(dropped.isEmpty)
        #expect(await store.isPinned("anything") == false)
    }

    @Test func offlineRootIsPersistedAcrossReinit() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 5, count: 40).write(to: source)
        await store.ingestCompleteFile(at: source, key: "durable_key", totalBytes: 40)

        // A fresh store over the same directory must restore pins and metas
        // exactly as the app would after a relaunch.
        let reopened = StreamCacheStore(directory: directory)
        #expect(await reopened.isComplete("durable_key"))
        #expect(await reopened.isPinned("durable_key"))
        let url = await reopened.fileURL(for: "durable_key")
        #expect(url.deletingLastPathComponent().path == offlineRoot.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removeUnpinnedKeyDoesNotTouchOfflineRoot() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 6, count: 30).write(to: source)
        await store.ingestCompleteFile(at: source, key: "keep_offline", totalBytes: 30)

        await store.setContentLength(10, for: "stream_only")
        await store.recordWrite(range: 0..<10, for: "stream_only")
        await store.remove(keys: ["stream_only"])

        #expect(await store.contains("keep_offline"))
        #expect(await store.isPinned("keep_offline"))
        #expect(FileManager.default.fileExists(
            atPath: offlineRoot.appendingPathComponent("keep_offline").path
        ))
    }

    @Test func removePinnedKeyClearsOfflineBlobAndMeta() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 25).write(to: source)
        await store.ingestCompleteFile(at: source, key: "remove_offline", totalBytes: 25)

        await store.remove(keys: ["remove_offline"])

        #expect(!(await store.contains("remove_offline")))
        #expect(!(await store.isPinned("remove_offline")))
        #expect(!FileManager.default.fileExists(
            atPath: offlineRoot.appendingPathComponent("remove_offline").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: offlineMetaRoot.appendingPathComponent("remove_offline.json").path
        ))
    }
}

// MARK: - Fix 2: phone→watch transfer resolves through the store

@Suite struct WatchChapterTransferTests {
    private var directory: URL!
    private var store: StreamCacheStore!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        store = StreamCacheStore(directory: directory)
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

    @Test func completeBlobResolvesToOfflineRootURL() async throws {
        let source = directory.appendingPathComponent("ingest-\(UUID().uuidString).bin")
        try Data(repeating: 8, count: 200).write(to: source)
        await store.ingestCompleteFile(at: source, key: "complete_chapter", totalBytes: 200)

        let url = await WatchChapterTransfer.resolvedFileURL(cacheStore: store, chapterKey: "complete_chapter")
        let resolved = try #require(url)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(try Data(contentsOf: resolved).count == 200)
    }
}
