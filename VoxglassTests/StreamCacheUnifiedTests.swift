import XCTest
@testable import VoxglassCore

final class StreamCacheUnifiedTests: XCTestCase {
    private var directory: URL!
    private var store: StreamCacheStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-cache-tests-\(UUID().uuidString)", isDirectory: true)
        store = StreamCacheStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
    }

    func testRegisterArtworkCountsIntoBytesButNotTrackCount() async {
        await store.registerArtwork(key: "art_a", bytes: 400)
        await store.registerArtwork(key: "art_b", bytes: 600)

        let bytes = await store.totalCachedBytes()
        let count = await store.cachedTrackCount()

        XCTAssertEqual(bytes, 1000)
        XCTAssertEqual(count, 0, "Artwork must not be counted as cached tracks")
    }

    func testCompletedAudioCountsAsTrackAlongsideArtworkBytes() async {
        await store.setContentLength(100, for: "audio1")
        await store.recordWrite(range: 0..<100, for: "audio1")
        await store.registerArtwork(key: "art_a", bytes: 250)

        let bytes = await store.totalCachedBytes()
        let count = await store.cachedTrackCount()

        XCTAssertEqual(bytes, 350)
        XCTAssertEqual(count, 1)
    }

    func testLRUEvictsAcrossKindsByLastAccess() async throws {
        await store.setLimit(250)

        await store.registerArtwork(key: "art_old", bytes: 100)
        try await Task.sleep(nanoseconds: 15_000_000)
        await store.setContentLength(100, for: "audio_mid")
        await store.recordWrite(range: 0..<100, for: "audio_mid")
        try await Task.sleep(nanoseconds: 15_000_000)

        // Touch the artwork so the audio entry becomes the oldest.
        await store.touch("art_old")
        try await Task.sleep(nanoseconds: 15_000_000)

        // Overflow the budget; oldest untouched entry (the audio) must be evicted.
        await store.registerArtwork(key: "art_new", bytes: 100)

        let hasArtOld = await store.contains("art_old")
        let hasAudioMid = await store.contains("audio_mid")
        let hasArtNew = await store.contains("art_new")

        XCTAssertTrue(hasArtOld)
        XCTAssertFalse(hasAudioMid, "Oldest untouched entry should be evicted regardless of kind")
        XCTAssertTrue(hasArtNew)
    }

    func testClearAllWipesBothDirectories() async throws {
        await store.setContentLength(10, for: "audio1")
        await store.recordWrite(range: 0..<10, for: "audio1")
        await store.registerArtwork(key: "art_a", bytes: 20)

        let audioURL = await store.fileURL(for: "audio1")
        let artURL = await store.artworkFileURL(for: "art_a")
        try Data(repeating: 1, count: 10).write(to: audioURL)
        try Data(repeating: 2, count: 20).write(to: artURL)

        let audioDir = audioURL.deletingLastPathComponent()
        let artDir = artURL.deletingLastPathComponent()

        await store.clearAll()

        let bytes = await store.totalCachedBytes()
        XCTAssertEqual(bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDir.path).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: artDir.path).count, 0)
    }

    // MARK: - §6/§7 remove, pin, ingest

    func testRemoveKeysTargetsOnlyGivenKeys() async {
        await store.setContentLength(100, for: "audio_keep")
        await store.recordWrite(range: 0..<100, for: "audio_keep")
        await store.setContentLength(100, for: "audio_drop")
        await store.recordWrite(range: 0..<100, for: "audio_drop")

        await store.remove(keys: ["audio_drop"])

        let keep = await store.contains("audio_keep")
        let drop = await store.contains("audio_drop")
        XCTAssertTrue(keep)
        XCTAssertFalse(drop)
    }

    func testIngestCompleteFileMarksCompleteAndPins() async throws {
        let source = directory.appendingPathComponent("ingest-source-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 100).write(to: source)

        await store.ingestCompleteFile(at: source, key: "audio_offline", totalBytes: 100)

        let complete = await store.isComplete("audio_offline")
        let pinned = await store.isPinned("audio_offline")
        let url = await store.fileURL(for: "audio_offline")
        XCTAssertTrue(complete)
        XCTAssertTrue(pinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, 100)
    }

    func testPinnedKeysAreExcludedFromEviction() async throws {
        let source = directory.appendingPathComponent("pin-source-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 100).write(to: source)
        await store.ingestCompleteFile(at: source, key: "pinned_audio", totalBytes: 100)

        await store.setContentLength(100, for: "unpinned_audio")
        await store.recordWrite(range: 0..<100, for: "unpinned_audio")

        // Non-pinned bytes (100) now exceed the limit; the pinned entry's bytes
        // are excluded from the budget and it must never be evicted.
        await store.setLimit(50)

        let pinned = await store.contains("pinned_audio")
        let unpinned = await store.contains("unpinned_audio")
        XCTAssertTrue(pinned, "Pinned offline content must survive eviction")
        XCTAssertFalse(unpinned, "Unpinned streaming content is evicted to fit budget")
    }

    func testRemoveUnpinsKeys() async throws {
        let source = directory.appendingPathComponent("unpin-source-\(UUID().uuidString).bin")
        try Data(repeating: 2, count: 50).write(to: source)
        await store.ingestCompleteFile(at: source, key: "to_unpin", totalBytes: 50)

        await store.remove(keys: ["to_unpin"])

        let pinned = await store.isPinned("to_unpin")
        let contains = await store.contains("to_unpin")
        XCTAssertFalse(pinned)
        XCTAssertFalse(contains)
    }

    func testLegacyMetaWithoutKindDecodesAsAudio() throws {
        let json = """
        {"cachedBytes":123,"complete":true,"lastAccessedAt":0,"createdAt":0,"rangeMap":{"ranges":[]}}
        """
        let meta = try JSONDecoder().decode(StreamCacheStore.Meta.self, from: Data(json.utf8))

        XCTAssertNil(meta.kind)
        XCTAssertEqual(meta.effectiveKind, .audio)
    }
}
