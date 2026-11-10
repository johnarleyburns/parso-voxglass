import Foundation
import VoxglassWatchProtocol

/// Compact per-book facts the MainActor needs to reconcile removed/revision bookkeeping.
public struct WatchCatalogBookMetadata: Sendable, Equatable {
    public var bookID: String
    public var metadataRevision: Int64
    public var isRemoving: Bool
}

/// A fully validated catalog, ready for one atomic MainActor commit. Durable bytes were already
/// persisted by the worker; `generation` lets the committer reject superseded completions.
public struct WatchCatalogCommit: Sendable, Equatable {
    public var snapshot: WatchLibrarySnapshot
    public var needsReconciliation: Bool
    public var sentAt: Date
    public var generation: UInt64
    public var books: [WatchCatalogBookMetadata]
}

public enum WatchCatalogIngestionResult: Sendable, Equatable {
    case accepted(WatchCatalogCommit)
    case ignoredStale
    case rejectedMalformed
}

/// Where encoded snapshot bytes are made durable. Called only from the ingestor's executor.
public protocol WatchCatalogDurableStore: Sendable {
    func save(_ data: Data)
}

public struct WatchUserDefaultsCatalogStore: WatchCatalogDurableStore {
    public static let snapshotKey = "watch.librarySnapshot"
    public init() {}
    public func save(_ data: Data) { UserDefaults.standard.set(data, forKey: Self.snapshotKey) }
}

public enum WatchCatalogRoute: Sendable, Equatable {
    case catalog(WatchCatalogIngestionResult)
    case other(WatchProtocolEnvelope)
    case unreadable
}

/// Off-MainActor owner of catalog envelope parsing, validation, encoding and persistence.
public actor WatchCatalogIngestor {
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
    private let store: any WatchCatalogDurableStore
    private var latestGeneration: UInt64 = 0
    private var acceptedRevision: (library: WatchPairedLibraryID, revision: Int64)?
    private var lastPersisted: Data?

    public init(store: any WatchCatalogDurableStore = WatchUserDefaultsCatalogStore()) { self.store = store }

    /// Classifies a raw envelope; library snapshots are ingested, everything else is returned.
    public func route(_ data: Data, generation: UInt64, current: WatchLibrarySnapshot?) -> WatchCatalogRoute {
        guard let envelope = try? WatchProtocolEnvelope.decode(data) else { return .unreadable }
        guard envelope.kind == .librarySnapshot else { return .other(envelope) }
        return .catalog(ingest(envelope, generation: generation, current: current))
    }

    public func ingest(_ data: Data, generation: UInt64, current: WatchLibrarySnapshot?) -> WatchCatalogIngestionResult {
        guard let envelope = try? WatchProtocolEnvelope.decode(data) else { return .rejectedMalformed }
        return ingest(envelope, generation: generation, current: current)
    }

    private func ingest(_ envelope: WatchProtocolEnvelope, generation: UInt64, current: WatchLibrarySnapshot?) -> WatchCatalogIngestionResult {
        guard envelope.kind == .librarySnapshot, envelope.version >= 2,
              var value = try? envelope.decodePayload(WatchLibrarySnapshot.self) else { return .rejectedMalformed }
        guard generation > latestGeneration else { return .ignoredStale }
        latestGeneration = generation
        if let current, current.pairedLibraryID == value.pairedLibraryID, current.revision > value.revision { return .ignoredStale }
        if let accepted = acceptedRevision, accepted.library == value.pairedLibraryID, accepted.revision > value.revision {
            return .ignoredStale
        }
        var seen = Set<WatchBookID>()
        value.books = value.books.filter { seen.insert($0.id).inserted }
        guard let encoded = try? Self.encoder.encode(value) else { return .rejectedMalformed }
        persist(encoded)
        acceptedRevision = (value.pairedLibraryID, value.revision)
        let metadata = value.books.map {
            WatchCatalogBookMetadata(bookID: $0.id.rawValue, metadataRevision: $0.metadataRevision,
                                     isRemoving: value.downloadStates?[$0.id] == .removing)
        }
        return .accepted(WatchCatalogCommit(
            snapshot: value,
            needsReconciliation: WatchPhonePushFiles.needsReconciliation(previous: current, next: value),
            sentAt: envelope.sentAt, generation: generation, books: metadata))
    }

    /// Persists an already-reduced snapshot (e.g. after a book removal), skipping equal bytes.
    public func persist(_ snapshot: WatchLibrarySnapshot) {
        if let encoded = try? Self.encoder.encode(snapshot) { persist(encoded) }
    }

    /// Forgets coalescing/ordering state after a reset wiped durable state.
    public func resetState() { lastPersisted = nil; acceptedRevision = nil }

    private func persist(_ encoded: Data) {
        guard encoded != lastPersisted else { return }
        store.save(encoded)
        lastPersisted = encoded
    }
}
