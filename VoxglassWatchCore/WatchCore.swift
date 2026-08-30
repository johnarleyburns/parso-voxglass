import Foundation
import VoxglassWatchProtocol

/// The watch store is intentionally a local Codable store. It has no sync engine, database
/// client, or network dependency; CloudKit is explicitly opted out by the watch product.
public struct WatchStoreConfiguration: Sendable, Equatable {
    public static let cloudKitDatabase = "none"
    public var storeURL: URL
    public var audioDirectory: URL
    public init(storeURL: URL, audioDirectory: URL) { self.storeURL=storeURL; self.audioDirectory=audioDirectory }
}

public struct WatchInstalledAsset: Codable, Equatable, Sendable {
    public var chapterID: WatchChapterID; public var relativePath: String; public var bytes: Int64; public var sha256: String
    public init(chapterID: WatchChapterID, relativePath: String, bytes: Int64, sha256: String) { self.chapterID=chapterID; self.relativePath=relativePath; self.bytes=bytes; self.sha256=sha256 }
}
public struct WatchBookRecord: Codable, Equatable, Sendable {
    public var book: WatchBookDTO; public var manifest: WatchManifest?; public var assets: [WatchInstalledAsset]; public var downloadState: WatchDownloadState
    public init(book: WatchBookDTO, manifest: WatchManifest? = nil, assets: [WatchInstalledAsset] = [], downloadState: WatchDownloadState = .notRequested) { self.book=book; self.manifest=manifest; self.assets=assets; self.downloadState=downloadState }
    public var isComplete: Bool { guard let manifest else { return false }; return manifest.requiredChapterIDs.allSatisfy { id in assets.contains { $0.chapterID == id } } }
}
public struct WatchStoreSnapshot: Codable, Equatable, Sendable {
    public var pairedLibraryID: WatchPairedLibraryID = .unknown; public var projectionRevision: Int64 = 0; public var books: [WatchBookID: WatchBookRecord] = [:]
    public init() {}
}

public actor WatchLocalStore {
    public let configuration: WatchStoreConfiguration
    private var snapshot: WatchStoreSnapshot
    private var loaded = false
    public init(configuration: WatchStoreConfiguration) { self.configuration=configuration; self.snapshot=WatchStoreSnapshot() }
    public func open() throws -> WatchStoreSnapshot {
        try FileManager.default.createDirectory(at: configuration.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.audioDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: configuration.storeURL.path) else { loaded=true; try persist(); return snapshot }
        do { snapshot = try JSONDecoder().decode(WatchStoreSnapshot.self, from: Data(contentsOf: configuration.storeURL)); loaded=true; return snapshot }
        catch { throw WatchStoreError.corrupt }
    }
    public func current() -> WatchStoreSnapshot { snapshot }
    public func replace(_ value: WatchStoreSnapshot) throws { snapshot=value; try persist() }
    public func upsert(_ book: WatchBookRecord) throws { snapshot.books[book.book.id]=book; try persist() }
    public func setManifest(_ manifest: WatchManifest, for bookID: WatchBookID) throws { guard var record=snapshot.books[bookID] else { throw WatchStoreError.unknownBook }; record.manifest=manifest; snapshot.books[bookID]=record; try persist() }
    public func markState(_ state: WatchDownloadState, for bookID: WatchBookID) throws { guard var record=snapshot.books[bookID] else { throw WatchStoreError.unknownBook }; record.downloadState=state; snapshot.books[bookID]=record; try persist() }
    public func completeBooks() -> [WatchBookRecord] { snapshot.books.values.filter(\.isComplete).sorted { $0.book.title < $1.book.title } }
    private func persist() throws { guard loaded || !FileManager.default.fileExists(atPath: configuration.storeURL.path) else { return }; let data=try JSONEncoder().encode(snapshot); try data.write(to: configuration.storeURL, options: .atomic) }
}

public enum WatchStoreError: Error, Equatable, Sendable { case corrupt, unknownBook, recoveryFailed }
public struct WatchStoreBootstrapResult: Sendable {
    public var store: WatchLocalStore?; public var recovered: Bool; public var preservedFiles: [String]; public var notice: String?
    public init(store: WatchLocalStore?, recovered: Bool, preservedFiles: [String], notice: String?) { self.store=store; self.recovered=recovered; self.preservedFiles=preservedFiles; self.notice=notice }
}
public enum WatchStoreBootstrap {
    public static func open(configuration: WatchStoreConfiguration) async -> WatchStoreBootstrapResult {
        let fm=FileManager.default; try? fm.createDirectory(at: configuration.audioDirectory, withIntermediateDirectories: true)
        let preserved=(try? fm.contentsOfDirectory(at: configuration.audioDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()) ?? []
        let store=WatchLocalStore(configuration: configuration)
        do { _ = try await store.open(); return .init(store: store, recovered: false, preservedFiles: [], notice: nil) }
        catch {
            let quarantine=configuration.storeURL.appendingPathExtension("quarantine-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: configuration.storeURL, to: quarantine)
            let fresh=WatchLocalStore(configuration: configuration)
            do { _ = try await fresh.open(); return .init(store: fresh, recovered: true, preservedFiles: preserved, notice: "Watch library rebuilt; downloaded audio was kept for reconciliation.") }
            catch { return .init(store: nil, recovered: true, preservedFiles: preserved, notice: "Watch library unavailable; downloaded audio was kept.") }
        }
    }
}

public enum WatchProjectionIngestor {
    public static func apply(_ incoming: WatchLibrarySnapshot, to current: WatchStoreSnapshot) -> Result<WatchStoreSnapshot, WatchProtocolFault> {
        guard current.pairedLibraryID == .unknown || current.pairedLibraryID == incoming.pairedLibraryID else { return .failure(.init(.wrongPair)) }
        guard incoming.revision >= current.projectionRevision else { return .success(current) }
        var result=current; result.pairedLibraryID=incoming.pairedLibraryID; result.projectionRevision=incoming.revision
        let existing=current.books
        result.books=Dictionary(uniqueKeysWithValues: incoming.books.map { dto in (dto.id, WatchBookRecord(book:dto, manifest: existing[dto.id]?.manifest, assets: existing[dto.id]?.assets ?? [], downloadState: existing[dto.id]?.downloadState ?? .notRequested)) })
        return .success(result)
    }
}
