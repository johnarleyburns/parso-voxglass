import Foundation
import Testing
import VoxglassCore

@Suite struct AssetStoreTests {

    @Test func putReturnsSameRefForSameData() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let data = Data("hello world".utf8)
        let ref1 = try await store.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original)
        let ref2 = try await store.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original)

        #expect(ref1.sha256 == ref2.sha256)
        #expect(ref1.relativePath == ref2.relativePath)
        #expect(store.exists(ref1))
    }

    @Test func ingestMovingFile() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let srcFile = tmp.appendingPathComponent("src.wav")
        try Data("test audio".utf8).write(to: srcFile)

        let ref = try await store.ingest(fileAt: srcFile, ext: "wav", contentType: "audio/wav", subdirectory: .original, moving: true)

        #expect(store.exists(ref))
        #expect(!FileManager.default.fileExists(atPath: srcFile.path))

        let loaded = try await store.data(for: ref)
        #expect(String(data: loaded, encoding: .utf8) == "test audio")
    }

    @Test func ingestCopyingPreservesSource() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let srcFile = tmp.appendingPathComponent("src_copy.wav")
        try Data("copy me".utf8).write(to: srcFile)

        let ref = try await store.ingest(fileAt: srcFile, ext: "wav", contentType: "audio/wav", subdirectory: .original, moving: false)

        #expect(store.exists(ref))
        #expect(FileManager.default.fileExists(atPath: srcFile.path))
    }

    @Test func trashMovesToTrashDirectory() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let data = Data("temporary".utf8)
        let ref = try await store.put(data, ext: "txt", contentType: "text/plain", subdirectory: .text)

        #expect(store.exists(ref))
        try await store.trash(ref)
        #expect(!store.exists(ref))
        let trashed = try await store.trashContents()
        #expect(trashed.count == 1)
        #expect(trashed.first?.sha256 == ref.sha256)
    }

    @Test func restoreFromTrashPutsAssetsBack() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let data = Data("restored".utf8)
        let ref = try await store.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original)

        try await store.trash(ref)
        #expect(!store.exists(ref))

        let restored = try await store.restoreFromTrash()
        #expect(restored.count == 1)
        #expect(store.exists(ref))
        let loaded = try await store.data(for: ref)
        #expect(String(data: loaded, encoding: .utf8) == "restored")
        let trashed = try await store.trashContents()
        #expect(trashed.isEmpty)
    }

    @Test func emptyTrashRemovesAll() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let ref = try await store.put(Data("gone".utf8), ext: "wav", contentType: "audio/wav", subdirectory: .original)
        try await store.trash(ref)
        try await store.emptyTrash()
        #expect(try await store.trashContents().isEmpty)
    }

    @Test func allReferencesEnumeratesFiles() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        try await store.put(Data("one".utf8), ext: "wav", contentType: "audio/wav", subdirectory: .original)
        try await store.put(Data("two".utf8), ext: "wav", contentType: "audio/wav", subdirectory: .original)

        let refs = try await store.allReferences(under: .original)
        #expect(refs.count == 2)
    }

    @Test func totalBytesSumsCorrectly() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        try await store.put(Data(repeating: 0, count: 1000), ext: "wav", contentType: "audio/wav", subdirectory: .original)
        try await store.put(Data(repeating: 0, count: 500), ext: "wav", contentType: "audio/wav", subdirectory: .original)

        let total = try await store.totalBytes(under: .original)
        #expect(total == 1500)
    }

    @Test func urlUsesRelativePath() async throws {
        let tmp = temporaryAssetStoreDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileAssetStore(root: tmp)
        let data = Data("positioned".utf8)
        let ref = try await store.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original)

        let url = store.url(for: ref)
        #expect(url.path.hasSuffix(".wav"))
        #expect(url.path.contains(ref.sha256))
    }

    private func temporaryAssetStoreDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asset_store_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
