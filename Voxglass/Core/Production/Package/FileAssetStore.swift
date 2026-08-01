import Foundation

public actor FileAssetStore: ContentAddressedStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    private func relativePath(sha: String, subdirectory: AssetSubdirectory, ext: String) -> String {
        let a = String(sha.prefix(2)), b = String(sha.dropFirst(2).prefix(2))
        return "\(subdirectory.rawValue)/\(a)/\(b)/\(sha).\(ext)"
    }

    private func fanoutDir(subdirectory: AssetSubdirectory, sha: String) -> URL {
        let a = String(sha.prefix(2)), b = String(sha.dropFirst(2).prefix(2))
        return root.appendingPathComponent("\(subdirectory.rawValue)/\(a)/\(b)", isDirectory: true)
    }

    public func put(_ data: Data, ext: String, contentType: String, subdirectory: AssetSubdirectory) async throws -> AudioAssetReference {
        let sha = SHA256Hex.hex(data)
        let relPath = relativePath(sha: sha, subdirectory: subdirectory, ext: ext)
        let ref = AudioAssetReference(sha256: sha, relativePath: relPath, byteCount: data.count, contentType: contentType)
        var destURL = root.appendingPathComponent(relativePath(sha: sha, subdirectory: subdirectory, ext: ext))

        if fm.fileExists(atPath: destURL.path) {
            return ref
        }

        let dir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmpURL = root.appendingPathComponent("tmp/\(UUID().uuidString)") // determinism-exempt: transient temp filename, never persisted
        let tmpDir = tmpURL.deletingLastPathComponent()
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch let error as NSError where error.code == NSFileWriteOutOfSpaceError {
            throw PackageError.diskFull(needBytes: Int64(data.count))
        }

        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: tmpURL)
            return ref
        }

        try fm.moveItem(at: tmpURL, to: destURL)

        let isCache = subdirectory == .render || subdirectory == .proxy
        var values = URLResourceValues()
        values.isExcludedFromBackup = isCache
        try? destURL.setResourceValues(values)

        return ref
    }

    public func ingest(fileAt url: URL, ext: String, contentType: String, subdirectory: AssetSubdirectory, moving: Bool) async throws -> AudioAssetReference {
        let sha = try SHA256Hex.hex(contentsOf: url)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let relPath = relativePath(sha: sha, subdirectory: subdirectory, ext: ext)
        let ref = AudioAssetReference(sha256: sha, relativePath: relPath, byteCount: fileSize, contentType: contentType)
        let destURL = root.appendingPathComponent(relativePath(sha: sha, subdirectory: subdirectory, ext: ext))

        if fm.fileExists(atPath: destURL.path) {
            if moving { try? fm.removeItem(at: url) }
            return ref
        }

        let dir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if moving {
            do {
                try fm.moveItem(at: url, to: destURL)
            } catch let error as NSError where error.code == NSFileWriteOutOfSpaceError {
                throw PackageError.diskFull(needBytes: Int64(fileSize))
            } catch {
                throw error
            }
        } else {
            do {
                try fm.copyItem(at: url, to: destURL)
            } catch let error as NSError where error.code == NSFileWriteOutOfSpaceError {
                throw PackageError.diskFull(needBytes: Int64(fileSize))
            } catch {
                throw error
            }
        }

        return ref
    }

    public nonisolated func url(for ref: AudioAssetReference) -> URL {
        root.appendingPathComponent(ref.relativePath)
    }

    public nonisolated func exists(_ ref: AudioAssetReference) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(ref.relativePath).path)
    }

    public func data(for ref: AudioAssetReference) async throws -> Data {
        let u = url(for: ref)
        return try Data(contentsOf: u)
    }

    public func trash(_ ref: AudioAssetReference) async throws {
        let sourceURL = url(for: ref)
        let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        // Mirror the content-addressed path under Trash/ so restore is
        // unambiguous without scanning every asset root.
        let destURL = trashDir.appendingPathComponent(ref.relativePath)
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: sourceURL, to: destURL)
    }

    /// Moves every asset under `Trash/` back to its content-addressed
    /// location. Returns the restored references.
    public func restoreFromTrash() async throws -> [AudioAssetReference] {
        let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        guard fm.fileExists(atPath: trashDir.path) else { return [] }

        let trashPrefix = trashDir.resolvingSymlinksInPath().path
        var restored: [AudioAssetReference] = []
        let enumerator = fm.enumerator(at: trashDir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let filePath = url.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(trashPrefix) else { continue }
            let relPath = String(filePath.dropFirst(trashPrefix.count + 1))
            guard !relPath.isEmpty else { continue }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let destURL = root.appendingPathComponent(relPath)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: destURL)
            restored.append(AudioAssetReference(
                sha256: url.deletingPathExtension().lastPathComponent,
                relativePath: relPath,
                byteCount: fileSize,
                contentType: contentTypeFor(ext: url.pathExtension)
            ))
        }
        return restored
    }

    public func emptyTrash() async throws {
        let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        guard fm.fileExists(atPath: trashDir.path) else { return }
        try fm.removeItem(at: trashDir)
    }

    public func trashContents() async throws -> [AudioAssetReference] {
        let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
        guard fm.fileExists(atPath: trashDir.path) else { return [] }
        let trashPrefix = trashDir.resolvingSymlinksInPath().path
        var refs: [AudioAssetReference] = []
        let enumerator = fm.enumerator(at: trashDir, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let filePath = url.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(trashPrefix) else { continue }
                let relPath = String(filePath.dropFirst(trashPrefix.count + 1))
                let ext = url.pathExtension
                let sha = url.deletingPathExtension().lastPathComponent
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                refs.append(AudioAssetReference(
                    sha256: sha,
                    relativePath: "Trash/\(relPath)",
                    byteCount: fileSize,
                    contentType: contentTypeFor(ext: ext)
                ))
            }
        }
        return refs
    }

    private func subdirectory(forShaPrefix sha: String, ext: String) -> AssetSubdirectory? {
        for subdir in AssetSubdirectory.allCases {
            let probe = relativePath(sha: sha, subdirectory: subdir, ext: ext)
            if fm.fileExists(atPath: root.appendingPathComponent(probe).path) {
                return subdir
            }
        }
        return nil
    }

    public func allReferences(under subdirectory: AssetSubdirectory) async throws -> [AudioAssetReference] {
        let dir = root.appendingPathComponent(subdirectory.rawValue, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let rootPrefix = root.resolvingSymlinksInPath().path
        var refs: [AudioAssetReference] = []
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let filePath = url.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(rootPrefix) else { continue }
                let relPath = String(filePath.dropFirst(rootPrefix.count + 1))
                let ext = url.pathExtension
                let sha = url.deletingPathExtension().lastPathComponent
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                refs.append(AudioAssetReference(sha256: sha, relativePath: relPath, byteCount: fileSize, contentType: contentTypeFor(ext: ext)))
            }
        }
        return refs
    }

    public func totalBytes(under subdirectory: AssetSubdirectory) async throws -> Int64 {
        let dir = root.appendingPathComponent(subdirectory.rawValue, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return 0 }

        var total: Int64 = 0
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func contentTypeFor(ext: String) -> String {
        switch ext.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "json": return "application/json"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
