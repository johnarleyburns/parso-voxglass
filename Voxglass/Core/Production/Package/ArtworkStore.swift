import Foundation

public enum ArtworkRole: String, Sendable, Equatable, CaseIterable {
    case coverOriginal
    case cover2400
}

public protocol ArtworkStore: Sendable {
    func store(_ data: Data, role: ArtworkRole, ext: String) async throws -> AudioAssetReference
    func load(role: ArtworkRole) async throws -> Data?
    func ref(role: ArtworkRole) async throws -> AudioAssetReference?
    func remove(role: ArtworkRole) async throws
    func allReferences() async throws -> [AudioAssetReference]
}

public struct FileArtworkStore: ArtworkStore {
    public let root: URL
    /// The `.voxproject` layout for this store — the single source of the
    /// package's path rules (§4.4).
    private var layout: ProductionProjectLayout { ProductionProjectLayout(root: root) }

    public init(root: URL) {
        self.root = root
    }

    private func url(for role: ArtworkRole, ext: String? = nil) throws -> URL {
        let dir = layout.artworkURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name: String
        switch role {
        case .coverOriginal:
            name = ext.map { "cover-original.\($0)" } ?? "cover-original.jpg"
        case .cover2400:
            name = "cover-2400.jpg"
        }
        return dir.appendingPathComponent(name)
    }

    public func store(_ data: Data, role: ArtworkRole, ext: String) async throws -> AudioAssetReference {
        let dest = try url(for: role, ext: ext)
        try data.write(to: dest, options: .atomic)
        let sha = SHA256Hex.hex(data)
        let relPath = String(dest.path.dropFirst(root.path.count + 1))
        return AudioAssetReference(sha256: sha, relativePath: relPath, byteCount: data.count, contentType: contentTypeFor(ext: ext))
    }

    public func load(role: ArtworkRole) async throws -> Data? {
        let dest = try url(for: role)
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        return try Data(contentsOf: dest)
    }

    public func ref(role: ArtworkRole) async throws -> AudioAssetReference? {
        let dest = try url(for: role)
        guard let data = try? Data(contentsOf: dest) else { return nil }
        return AudioAssetReference(
            sha256: SHA256Hex.hex(data),
            relativePath: String(dest.path.dropFirst(root.path.count + 1)),
            byteCount: data.count,
            contentType: contentTypeFor(ext: dest.pathExtension)
        )
    }

    public func remove(role: ArtworkRole) async throws {
        let dest = try url(for: role)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }

    public func allReferences() async throws -> [AudioAssetReference] {
        let dir = layout.artworkURL
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        var refs: [AudioAssetReference] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue {
                let relPath = String(item.path.dropFirst(root.path.count + 1))
                let fileSize = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                refs.append(AudioAssetReference(
                    sha256: SHA256Hex.hex(contentsOf: item) ?? "",
                    relativePath: relPath,
                    byteCount: fileSize,
                    contentType: contentTypeFor(ext: item.pathExtension)
                ))
            }
        }
        return refs
    }

    private func contentTypeFor(ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }
}

public actor InMemoryArtworkStore: ArtworkStore {
    private var storage: [ArtworkRole: AudioAssetReference] = [:]
    private var blobs: [ArtworkRole: Data] = [:]

    public init() {}

    public func store(_ data: Data, role: ArtworkRole, ext: String) async throws -> AudioAssetReference {
        let ref = AudioAssetReference(
            sha256: SHA256Hex.hex(data),
            relativePath: "Artwork/\(role.rawValue).\(ext)",
            byteCount: data.count,
            contentType: ext.lowercased() == "png" ? "image/png" : "image/jpeg"
        )
        storage[role] = ref
        blobs[role] = data
        return ref
    }

    public func load(role: ArtworkRole) async throws -> Data? {
        blobs[role]
    }

    public func ref(role: ArtworkRole) async throws -> AudioAssetReference? {
        storage[role]
    }

    public func remove(role: ArtworkRole) async throws {
        storage.removeValue(forKey: role)
        blobs.removeValue(forKey: role)
    }

    public func allReferences() async throws -> [AudioAssetReference] {
        Array(storage.values)
    }
}

private extension SHA256Hex {
    static func hex(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return hex(data)
    }
}
