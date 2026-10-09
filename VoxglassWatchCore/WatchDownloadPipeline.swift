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

extension WatchDownloadPipelineError: LocalizedError {
    /// Readable installation diagnostics instead of an opaque Swift error number.
    public var errorDescription: String? {
        switch self {
        case .missingSource: "The audio source is missing."
        case .sizeMismatch: "The received file is incomplete or has the wrong size."
        case .checksumMismatch: "The received file failed its integrity check."
        case .insufficientStorage: "There is not enough free storage on Apple Watch."
        case .invalidFilename: "The file has an invalid destination name."
        case .missingBook: "The matching book metadata is missing."
        case .cancelled: "The transfer was cancelled."
        }
    }
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
        var hash = SHA256()
        // Each `read(upToCount:)` bridges through Foundation's NSData; without
        // draining the autorelease pool per chunk, those bridged buffers all
        // stay alive for the whole loop — for a GB-scale file that alone can
        // balloon peak memory by the size of the file being hashed.
        while true {
            var stop = false
            try autoreleasepool {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { stop = true; return }
                hash.update(data: chunk)
            }
            if stop { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Synchronous ownership of Apple's temporary file, followed by disk-derived installation truth.
public enum WatchPhonePushFiles {
    /// Resume/status-only metadata must not rehash an entire audiobook every sync.
    public static func needsReconciliation(previous: WatchLibrarySnapshot?, next: WatchLibrarySnapshot) -> Bool {
        guard let previous, previous.pairedLibraryID == next.pairedLibraryID,
              previous.books.count == next.books.count else { return true }
        for book in next.books {
            guard let old = previous.books.first(where: { $0.id == book.id }),
                  old.metadataRevision == book.metadataRevision, old.chapters.count == book.chapters.count else { return true }
            for (left, right) in zip(old.chapters, book.chapters) {
                if left.id != right.id || left.durableFilename != right.durableFilename
                    || left.expectedBytes != right.expectedBytes || left.expectedSHA256 != right.expectedSHA256 { return true }
            }
        }
        return false
    }

    /// Reject traversal before constructing any durable path.
    public static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value != "." && value != ".."
            && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/") && !value.contains("\\")
            && !value.contains("\0")
    }

    /// Copy and validate during WCSession's callback; never defer ownership of its temporary URL.
    public static func install(source: URL, root: URL, bookID: String, filename: String,
                               expectedBytes: Int64, expectedSHA256: String,
                               validateAudio: ((URL) throws -> Void)? = nil) throws -> URL {
        guard safeComponent(bookID), safeComponent(filename), expectedBytes > 0 else {
            throw WatchDownloadPipelineError.invalidFilename
        }
        let directory = root.appendingPathComponent(bookID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        let staged = directory.appendingPathComponent(".incoming-" + filename)
        defer { try? FileManager.default.removeItem(at: staged) }
        if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        let bytes = (try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard bytes == expectedBytes else { throw WatchDownloadPipelineError.sizeMismatch }
        guard try WatchChecksum.sha256(of: staged) == expectedSHA256.lowercased() else {
            throw WatchDownloadPipelineError.checksumMismatch
        }
        try validateAudio?(staged)
        if FileManager.default.fileExists(atPath: destination.path) {
            if try WatchChecksum.sha256(of: destination) == expectedSHA256.lowercased() { return destination }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        return destination
    }

    /// Reconcile unique chapter IDs from validated files, including after relaunch or reordering.
    public static func report(book: WatchBookDTO, root: URL) -> WatchManifestAcknowledgement {
        var seen = Set<WatchChapterID>()
        var bytes: Int64 = 0
        var installed: [WatchChapterID] = []
        for chapter in book.chapters where seen.insert(chapter.id).inserted {
            guard safeComponent(book.id.rawValue), safeComponent(chapter.durableFilename),
                  let expected = chapter.expectedBytes, let hash = chapter.expectedSHA256 else { continue }
            let url = root.appendingPathComponent(book.id.rawValue).appendingPathComponent(chapter.durableFilename)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == expected, (try? WatchChecksum.sha256(of: url)) == hash.lowercased() else { continue }
            bytes += Int64(size); installed.append(chapter.id)
        }
        var value = WatchManifestAcknowledgement(bookID: book.id, revision: book.metadataRevision,
            complete: !book.chapters.isEmpty && installed.count == Set(book.chapters.map(\.id)).count,
            installedBytes: bytes)
        value.installedChapterIDs = installed
        return value
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
