import Foundation
import Testing
import ParsoAudioStreaming
@testable import VoxglassCore

@Suite(.serialized) struct CacheSettingsModelTests {

    @Test func storageUsageSeparatesStreamingAndOfflineBytes() async {
        await AudioCache.clearCache()
        await AudioCache.shared.registerComplete(key: "stream_usage", bytes: 1_024, kind: "audio")
        await AudioCache.shared.registerComplete(key: "offline_usage", bytes: 2_048, kind: "audio")
        await AudioCache.shared.pin(["offline_usage"])

        let usage = await AudioCache.storageUsage()
        #expect(usage.streamingBytes == 1_024)
        #expect(usage.durableBytes == 2_048)
        #expect(usage.totalBytes == 3_072)
        #expect(usage.streamingAudioCount == 1)
        #expect(usage.durableAudioCount == 1)

        await AudioCache.clearStreamingCache()
        let afterStreamingClear = await AudioCache.storageUsage()
        #expect(afterStreamingClear.streamingBytes == 0)
        #expect(afterStreamingClear.durableBytes == 2_048)

        await AudioCache.clearOfflineCache()
        let afterOfflineClear = await AudioCache.storageUsage()
        #expect(afterOfflineClear.totalBytes == 0)
    }

    @Test func clearCacheEmptiesTheStore() async {
        await AudioCache.shared.registerComplete(key: "art_test_clear", bytes: 1024, kind: "artwork")
        let before = await AudioCache.shared.totalCachedBytes()
        #expect(before >= 1024)

        await AudioCache.clearCache()

        let after = await AudioCache.shared.totalCachedBytes()
        #expect(after == 0)
    }

    @Test func clearingCacheNeverDeletesLocalBookFilesOrLibraryRows() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-local-book-\(UUID().uuidString)", isDirectory: true)
        let localFile = folder.appendingPathComponent("chapter-01.mp3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("local book audio".utf8).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: folder) }

        let database = AppDatabase.makeTemporaryDatabase(named: "cache-clear-local-book")
        let repository = LibraryRepository(database: database)
        let imported = try await repository.importLocalFolder(
            folderURL: folder,
            folderName: "Local Book",
            files: [LocalAudioImport(
                url: localFile,
                title: "Chapter 1",
                sortKey: "chapter-01.mp3",
                duration: 60
            )]
        )

        await AudioCache.shared.registerComplete(key: "cache_clear_sentinel", bytes: 1_024, kind: "audio")
        await AudioCache.clearCache()

        let library = try await repository.fetchLibrary()
        #expect(FileManager.default.fileExists(atPath: localFile.path))
        #expect(library.contains { $0.book.id == imported.book.id })
        #expect(library.first?.chapters.first?.localURL == localFile)
    }
}
