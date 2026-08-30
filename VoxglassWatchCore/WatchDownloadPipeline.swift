import Foundation
import CryptoKit
import VoxglassWatchProtocol

public enum WatchAssetPurpose: String, Codable, Sendable { case durable, ephemeral }
public enum WatchAssetValidation: String, Codable, Sendable { case staged, valid, invalid }

public struct WatchDownloadAsset: Codable, Equatable, Sendable {
    public var chapterID: WatchChapterID
    public var sourceURL: URL?
    public var expectedBytes: Int64?
    public var expectedSHA256: String?
    public var filename: String
    public var purpose: WatchAssetPurpose
    public init(chapterID: WatchChapterID, sourceURL: URL?, expectedBytes: Int64? = nil,
                expectedSHA256: String? = nil, filename: String, purpose: WatchAssetPurpose = .durable) {
        self.chapterID = chapterID; self.sourceURL = sourceURL; self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256; self.filename = filename; self.purpose = purpose
    }
}

public struct WatchDownloadPlan: Codable, Equatable, Sendable {
    public var bookID: WatchBookID; public var revision: Int64; public var assets: [WatchDownloadAsset]
    public var artworkURL: URL?; public var estimatedBytes: Int64
    public init(bookID: WatchBookID, revision: Int64, assets: [WatchDownloadAsset], artworkURL: URL? = nil) {
        self.bookID = bookID; self.revision = revision; self.assets = assets; self.artworkURL = artworkURL
        self.estimatedBytes = assets.compactMap(\.expectedBytes).reduce(0, +)
    }
    public var manifest: WatchManifest { .init(bookID: bookID, revision: revision, requiredChapterIDs: assets.map(\.chapterID)) }
}

public enum WatchDownloadPipelineError: Error, Equatable, Sendable {
    case missingSource(WatchChapterID), sizeMismatch, checksumMismatch, insufficientStorage(required: Int64, available: Int64)
    case invalidFilename, missingBook, cancelled
}

public struct WatchStorageReserve: Sendable, Equatable {
    public static let minimumBytes: Int64 = 250 * 1024 * 1024
    public var requiredBytes: Int64; public var availableBytes: Int64
    public init(requiredBytes: Int64, availableBytes: Int64) { self.requiredBytes = requiredBytes; self.availableBytes = availableBytes }
    public var isSufficient: Bool { availableBytes >= requiredBytes }
    public static func required(for estimate: Int64, freeBytes: Int64) -> Int64 { max(minimumBytes, estimate, max(0, freeBytes / 10)) }
}

public enum WatchChecksum {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256();
        while true { let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data(); if chunk.isEmpty { break }; hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public actor WatchFileInstaller {
    public let durableRoot: URL
    public let stagingRoot: URL
    private let fileManager = FileManager.default

    public init(durableRoot: URL, stagingRoot: URL? = nil) {
        self.durableRoot = durableRoot; self.stagingRoot = stagingRoot ?? durableRoot.appendingPathComponent(".staging", isDirectory: true)
        try? fileManager.createDirectory(at: durableRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.stagingRoot, withIntermediateDirectories: true)
    }

    public func install(plan: WatchDownloadPlan, availableBytes: Int64, copy: @Sendable (URL, URL) throws -> Void = { source, destination in try FileManager.default.copyItem(at: source, to: destination) }) async throws -> WatchManifestAcknowledgement {
        let reserve = WatchStorageReserve.required(for: plan.estimatedBytes, freeBytes: availableBytes)
        guard availableBytes >= reserve else { throw WatchDownloadPipelineError.insufficientStorage(required: reserve, available: availableBytes) }
        let root = stagingRoot.appendingPathComponent(plan.bookID.rawValue, isDirectory: true)
        try? fileManager.removeItem(at: root); try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var installed: [WatchInstalledAsset] = []
        do {
            for asset in plan.assets {
                guard asset.filename == URL(fileURLWithPath: asset.filename).lastPathComponent, !asset.filename.isEmpty else { throw WatchDownloadPipelineError.invalidFilename }
                guard let source = asset.sourceURL, source.isFileURL, fileManager.fileExists(atPath: source.path) else { throw WatchDownloadPipelineError.missingSource(asset.chapterID) }
                let staged = root.appendingPathComponent(asset.filename)
                try copy(source, staged)
                let bytes = Int64((try fileManager.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0)
                guard asset.expectedBytes == nil || asset.expectedBytes == bytes else { throw WatchDownloadPipelineError.sizeMismatch }
                let digest = try WatchChecksum.sha256(of: staged)
                guard asset.expectedSHA256 == nil || asset.expectedSHA256?.lowercased() == digest else { throw WatchDownloadPipelineError.checksumMismatch }
                installed.append(.init(chapterID: asset.chapterID, relativePath: asset.filename, bytes: bytes, sha256: digest))
            }
            let final = durableRoot.appendingPathComponent(plan.bookID.rawValue, isDirectory: true)
            let backup = durableRoot.appendingPathComponent(".old-\(plan.bookID.rawValue)", isDirectory: true)
            try? fileManager.removeItem(at: backup); if fileManager.fileExists(atPath: final.path) { try fileManager.moveItem(at: final, to: backup) }
            try fileManager.moveItem(at: root, to: final); try? fileManager.removeItem(at: backup)
            return .init(bookID: plan.bookID, revision: plan.revision, complete: installed.count == plan.assets.count, installedBytes: installed.reduce(0) { $0 + $1.bytes })
        } catch { try? fileManager.removeItem(at: root); throw error }
    }

    public func remove(bookID: WatchBookID) { try? fileManager.removeItem(at: durableRoot.appendingPathComponent(bookID.rawValue)); try? fileManager.removeItem(at: stagingRoot.appendingPathComponent(bookID.rawValue)) }
}

public enum WatchManifestReconciler {
    public static func acknowledgement(book: WatchBookRecord, root: URL) -> WatchManifestAcknowledgement? {
        guard let manifest = book.manifest else { return nil }
        let valid = manifest.requiredChapterIDs.allSatisfy { id in
            guard let asset = book.assets.first(where: { $0.chapterID == id }) else { return false }
            let url = root.appendingPathComponent(asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path), (try? WatchChecksum.sha256(of: url)) == asset.sha256 else { return false }
            return true
        }
        return .init(bookID: manifest.bookID, revision: manifest.revision, complete: valid, installedBytes: valid ? book.assets.reduce(0) { $0 + $1.bytes } : 0)
    }
}
