import Foundation
import VoxglassCore

/// A `RenderCache` backed by the project package's `Audio/Render/` directory
/// (§4.4). The index maps a `RenderCacheKey` to the content-addressed render
/// file it produced. Renders are the first thing evicted under storage
/// pressure (§6.5), so a miss just means "render it again" — never a lost take.
public struct ProductionRenderCache: RenderCache, Sendable {
    public let root: URL
    public let fileStore: FileAssetStore

    /// The JSON index file inside the render directory.
    public var indexURL: URL { root.appendingPathComponent("render-cache.json") }

    public init(root: URL, fileStore: FileAssetStore) {
        self.root = root
        self.fileStore = fileStore
    }

    public func cachedRender(for key: String) async throws -> AudioAssetReference? {
        let index = try readIndex()
        guard let ref = index[key], fileStore.exists(ref) else { return nil }
        return ref
    }

    public func store(_ ref: AudioAssetReference, for key: String) async throws {
        var index = try readIndex()
        index[key] = ref
        try writeIndex(index)
    }

    /// Removes every render file and its index entries (mockup 10
    /// `assemble.clearCache`). Renders rebuild from the original takes.
    public func clear() async throws {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent != "render-cache.json" {
                try? fm.removeItem(at: entry)
            }
        }
        try? fm.removeItem(at: indexURL)
    }

    // MARK: - Index

    private func readIndex() throws -> [String: AudioAssetReference] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode([String: AudioAssetReference].self, from: data)
    }

    private func writeIndex(_ index: [String: AudioAssetReference]) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }
}
