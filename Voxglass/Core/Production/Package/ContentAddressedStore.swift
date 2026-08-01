import Foundation

/// The §4.7 package layout's asset subdirectories.
public enum AssetSubdirectory: String, Sendable, CaseIterable {
    case original = "Audio/Original"
    case render = "Audio/Render"
    case proxy = "Audio/Proxy"
    case source = "Text/source"
    case extracted = "Text/extracted"
    case text = "Text"
    case artwork = "Artwork"
}

public protocol ContentAddressedStore: Sendable {
    func url(for ref: AudioAssetReference) -> URL
    func exists(_ ref: AudioAssetReference) -> Bool
    func put(_ data: Data, ext: String, contentType: String, subdirectory: AssetSubdirectory) async throws -> AudioAssetReference
    func ingest(fileAt url: URL, ext: String, contentType: String, subdirectory: AssetSubdirectory, moving: Bool) async throws -> AudioAssetReference
    func data(for ref: AudioAssetReference) async throws -> Data
    func trash(_ ref: AudioAssetReference) async throws
    func allReferences(under subdirectory: AssetSubdirectory) async throws -> [AudioAssetReference]
    func totalBytes(under subdirectory: AssetSubdirectory) async throws -> Int64
}
