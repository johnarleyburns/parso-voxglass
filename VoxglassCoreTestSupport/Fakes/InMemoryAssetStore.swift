import Foundation
import VoxglassCore

/// In-memory `ContentAddressedStore` for tests. Contents are keyed by SHA-256;
/// `ingest` reads the file at the given URL into memory (with optional move),
/// so `data(for:)` and `byteCount` behave like `FileAssetStore`.
public actor InMemoryAssetStore: ContentAddressedStore {
    public private(set) var contents: [String: (subdirectory: AssetSubdirectory, ext: String, contentType: String, data: Data)] = [:]
    public private(set) var trashed: [AudioAssetReference] = []

    public init() {}

    public nonisolated func url(for ref: AudioAssetReference) -> URL {
        URL(fileURLWithPath: "/in-memory/\(ref.relativePath)")
    }

    public nonisolated func exists(_ ref: AudioAssetReference) -> Bool {
        false
    }

    public func put(_ data: Data, ext: String, contentType: String, subdirectory: AssetSubdirectory) async throws -> AudioAssetReference {
        let sha = SHA256Hex.hex(data)
        contents[sha] = (subdirectory, ext, contentType, data)
        return AudioAssetReference(sha256: sha, relativePath: "\(subdirectory.rawValue)/\(sha).\(ext)", byteCount: data.count, contentType: contentType)
    }

    public func ingest(fileAt url: URL, ext: String, contentType: String, subdirectory: AssetSubdirectory, moving: Bool) async throws -> AudioAssetReference {
        let data = try Data(contentsOf: url)
        if moving { try? FileManager.default.removeItem(at: url) }
        return try await put(data, ext: ext, contentType: contentType, subdirectory: subdirectory)
    }

    public func data(for ref: AudioAssetReference) async throws -> Data {
        guard let entry = contents[ref.sha256] else {
            throw StoreError.notFound(UUID())
        }
        return entry.data
    }

    public func trash(_ ref: AudioAssetReference) async throws {
        trashed.append(ref)
        contents.removeValue(forKey: ref.sha256)
    }

    public func allReferences(under subdirectory: AssetSubdirectory) async throws -> [AudioAssetReference] {
        contents.compactMap { sha, entry in
            guard entry.subdirectory == subdirectory else { return nil }
            return AudioAssetReference(sha256: sha, relativePath: "\(subdirectory.rawValue)/\(sha).\(entry.ext)", byteCount: entry.data.count, contentType: entry.contentType)
        }
    }

    public func totalBytes(under subdirectory: AssetSubdirectory) async throws -> Int64 {
        contents.reduce(into: 0) { total, entry in
            if entry.value.subdirectory == subdirectory { total += Int64(entry.value.data.count) }
        }
    }
}
