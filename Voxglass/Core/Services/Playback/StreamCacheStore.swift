import Foundation

/// Streaming byte-range cache accounting: limit, LRU eviction, GC of stale partials.
/// The cache is passive: nothing here initiates caching of a chapter the player
/// didn't request. It only stores/evicts what flows through the resource loader.
///
/// Two storage roots (INV-A):
/// - **Streaming cache** (unpinned, evictable) lives under `Caches` — the system
///   may reclaim it at any time.
/// - **Offline store** (pinned, durable) lives under Application Support,
///   excluded from iCloud backup. Blobs the user explicitly downloaded for
///   offline use must never sit in a purgeable directory (RC1).
public actor StreamCacheStore {
    public static let shared = StreamCacheStore()

    public enum EntryKind: String, Codable { case audio, artwork }

    public struct Meta: Codable {
        var totalBytes: Int64?
        var cachedBytes: Int64
        var complete: Bool
        var lastAccessedAt: Date
        var createdAt: Date
        var rangeMap: ByteRangeMap
        var kind: EntryKind?          // nil == .audio for back-compat with legacy JSON

        var effectiveKind: EntryKind { kind ?? .audio }
    }

    private let dir: URL
    private let artDir: URL
    private let metaDir: URL
    private let offlineDir: URL
    private let offlineMetaDir: URL
    private let pinsURL: URL
    private var metas: [String: Meta] = [:]   // key = cacheKey
    private var pinnedKeys: Set<String> = []   // never evicted (offline downloads, §7)
    private var limitBytes: Int64

    /// Cache keys that were pinned before the offline-store migration but whose
    /// blob was already purged by the system. Read by the app layer after
    /// bootstrap so their `download_records` can be deleted (the UI must show
    /// them as not-downloaded, not falsely "cached").
    public private(set) var droppedLegacyPinKeys: [String] = []

    public static let defaultLimit: Int64 = 500 * 1024 * 1024

    public static func cacheBaseDirectory() -> URL {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Sibling artwork blob directory shared with `ArtworkService`'s disk tier.
    public static var defaultArtworkDirectory: URL {
        cacheBaseDirectory().appendingPathComponent("Voxglass/StreamCacheArt", isDirectory: true)
    }

    /// Durable root for pinned (user-downloaded) audio: Application Support so
    /// the system never reclaims it, excluded from iCloud backup so re-downloads
    /// stay re-downloadable.
    public static func offlineBaseDirectory() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public init() {
        let base = Self.cacheBaseDirectory()
        dir = base.appendingPathComponent("Voxglass/StreamCache", isDirectory: true)
        artDir = base.appendingPathComponent("Voxglass/StreamCacheArt", isDirectory: true)
        metaDir = base.appendingPathComponent("Voxglass/StreamCacheMeta", isDirectory: true)

        let durable = Self.offlineBaseDirectory()
        offlineDir = durable.appendingPathComponent("Voxglass/OfflineAudio", isDirectory: true)
        offlineMetaDir = durable.appendingPathComponent("Voxglass/OfflineMeta", isDirectory: true)
        pinsURL = durable.appendingPathComponent("Voxglass/OfflinePins.json")

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: offlineDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: offlineMetaDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var offlineURL = offlineDir
        try? offlineURL.setResourceValues(values)
        var offlineMetaURL = offlineMetaDir
        try? offlineMetaURL.setResourceValues(values)

        limitBytes = Self.defaultLimit
        metas = Self.loadMetas(from: metaDir, and: offlineMetaDir)
        pinnedKeys = Self.loadPinnedKeys(from: pinsURL)
        droppedLegacyPinKeys = migrateLegacyPinnedBlobs()
    }

    /// Testable init that isolates all state under a caller-supplied directory.
    public init(directory: URL) {
        dir = directory.appendingPathComponent("StreamCache", isDirectory: true)
        artDir = directory.appendingPathComponent("StreamCacheArt", isDirectory: true)
        metaDir = directory.appendingPathComponent("StreamCacheMeta", isDirectory: true)
        offlineDir = directory.appendingPathComponent("OfflineAudio", isDirectory: true)
        offlineMetaDir = directory.appendingPathComponent("OfflineMeta", isDirectory: true)
        pinsURL = directory.appendingPathComponent("OfflinePins.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlineDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlineMetaDir, withIntermediateDirectories: true)
        limitBytes = Self.defaultLimit
        metas = Self.loadMetas(from: metaDir, and: offlineMetaDir)
        pinnedKeys = Self.loadPinnedKeys(from: pinsURL)
    }

    // MARK: - Public accounting

    public func currentLimit() -> Int64 { limitBytes }

    public func setLimit(_ bytes: Int64) async {
        limitBytes = bytes
        await evictToFit(protecting: nil)
    }

    public func totalCachedBytes() -> Int64 {
        metas.values.reduce(0) { $0 + $1.cachedBytes }
    }

    /// Audio tracks only — cover images are excluded from the "N tracks cached" count.
    public func cachedTrackCount() -> Int {
        metas.values.filter { $0.complete && $0.effectiveKind == .audio }.count
    }

    public func contains(_ key: String) -> Bool {
        metas[key] != nil
    }

    /// True when the full audio file for `key` is present.
    public func isComplete(_ key: String) -> Bool {
        completeAudioFileURL(for: key) != nil
    }

    public func isPinned(_ key: String) -> Bool {
        pinnedKeys.contains(key)
    }

    // MARK: - Pinning (offline downloads, §7)

    /// Marks keys as pinned so they are never evicted or GC'd, and **moves** any
    /// existing blob + meta from the streaming root into the durable offline
    /// root. Pinned bytes are also excluded from the streaming-budget eviction
    /// total.
    public func pin(_ keys: [String]) {
        let fm = FileManager.default
        for key in keys {
            let streamingBlob = dir.appendingPathComponent(key)
            let offlineBlob = offlineDir.appendingPathComponent(key)
            if fm.fileExists(atPath: streamingBlob.path) {
                if fm.fileExists(atPath: offlineBlob.path) {
                    try? fm.removeItem(at: streamingBlob)
                } else {
                    try? fm.moveItem(at: streamingBlob, to: offlineBlob)
                }
            }
            let streamingMeta = metaDir.appendingPathComponent("\(key).json")
            let offlineMeta = offlineMetaDir.appendingPathComponent("\(key).json")
            if fm.fileExists(atPath: streamingMeta.path) {
                if fm.fileExists(atPath: offlineMeta.path) {
                    try? fm.removeItem(at: streamingMeta)
                } else {
                    try? fm.moveItem(at: streamingMeta, to: offlineMeta)
                }
            }
            pinnedKeys.insert(key)
        }
        persistPinnedKeys()
    }

    /// Un-pins keys: moves their blob + meta back into the streaming root (or
    /// simply drops them if the offline blob is gone).
    public func unpin(_ keys: [String]) {
        let fm = FileManager.default
        for key in keys where pinnedKeys.contains(key) {
            let offlineBlob = offlineDir.appendingPathComponent(key)
            let streamingBlob = dir.appendingPathComponent(key)
            if fm.fileExists(atPath: offlineBlob.path) {
                try? fm.removeItem(at: streamingBlob)
                try? fm.moveItem(at: offlineBlob, to: streamingBlob)
            }
            let offlineMeta = offlineMetaDir.appendingPathComponent("\(key).json")
            let streamingMeta = metaDir.appendingPathComponent("\(key).json")
            if fm.fileExists(atPath: offlineMeta.path) {
                try? fm.removeItem(at: streamingMeta)
                try? fm.moveItem(at: offlineMeta, to: streamingMeta)
            }
            pinnedKeys.remove(key)
        }
        persistPinnedKeys()
    }

    /// Removes the given keys' blobs + metadata, and unpins them. Public entry
    /// point used when purging a book's cache (§6) or removing an offline copy (§7).
    public func remove(keys: [String]) {
        for key in keys {
            remove(key)
        }
        let removed = Set(keys)
        if !pinnedKeys.isDisjoint(with: removed) {
            pinnedKeys.subtract(removed)
            persistPinnedKeys()
        }
    }

    /// Ingests a fully-downloaded file (delivered complete by a background
    /// `URLSession` download task, not streamed in ranges): moves it into the
    /// durable offline root (it is pinned for offline use), records the full
    /// range, marks it complete, and pins it.
    public func ingestCompleteFile(at tempURL: URL, key: String, totalBytes: Int64) async {
        let destination = offlineDir.appendingPathComponent(key)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            // Fall back to a copy if the temp file lives on another volume.
            try? fm.copyItem(at: tempURL, to: destination)
        }

        let resolvedTotal = totalBytes > 0
            ? totalBytes
            : (Int64((try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0))
        let now = Date()
        var map = ByteRangeMap()
        if resolvedTotal > 0 { map.insert(0..<resolvedTotal) }
        // Pin before persisting the meta so the meta file lands in the offline
        // meta directory alongside the durable blob.
        pin([key])
        metas[key] = Meta(
            totalBytes: resolvedTotal,
            cachedBytes: resolvedTotal,
            complete: true,
            lastAccessedAt: now,
            createdAt: metas[key]?.createdAt ?? now,
            rangeMap: map,
            kind: .audio
        )
        persistMeta(key)
    }

    public func fileURL(for key: String) -> URL {
        if metas[key]?.effectiveKind == .artwork {
            return artDir.appendingPathComponent(key)
        }
        if pinnedKeys.contains(key) {
            return offlineDir.appendingPathComponent(key)
        }
        return dir.appendingPathComponent(key)
    }

    /// Returns a real on-disk audio URL only when the cache metadata and blob are
    /// both complete. This lets playback bypass the remote resource loader for
    /// fully cached chapters, which is required for offline/downloaded books.
    public func completeAudioFileURL(for key: String) -> URL? {
        guard let meta = metas[key],
              meta.effectiveKind == .audio,
              meta.complete else { return nil }

        let url = fileURL(for: key)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            discardCachedBytes(for: key, unpin: pinnedKeys.contains(key))
            return nil
        }

        let actualBytes = size.int64Value
        let expectedBytes = meta.totalBytes ?? meta.cachedBytes
        guard actualBytes > 0,
              expectedBytes <= 0 || actualBytes >= expectedBytes else {
            discardCachedBytes(for: key, unpin: pinnedKeys.contains(key))
            return nil
        }

        touch(key)
        return url
    }

    /// Number of contiguous cached bytes that are backed by a readable file.
    /// Stale metadata from a purged/truncated cache blob is cleared before
    /// returning 0 so the resource loader falls through to the network path.
    public func cachedContiguousBytes(for key: String, from offset: Int64) -> Int64 {
        guard let meta = metas[key] else { return 0 }
        let contiguous = meta.rangeMap.contiguousBytes(from: offset)
        guard contiguous > 0 else { return 0 }

        let url = fileURL(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            discardCachedBytes(for: key, unpin: pinnedKeys.contains(key))
            return 0
        }

        let actualBytes = size.int64Value
        guard actualBytes >= offset + contiguous else {
            discardCachedBytes(for: key, unpin: pinnedKeys.contains(key))
            return 0
        }

        touch(key)
        return contiguous
    }

    public func artworkFileURL(for key: String) -> URL {
        artDir.appendingPathComponent(key)
    }

    /// Upsert a complete artwork entry, then evict across the unified budget.
    public func registerArtwork(key: String, bytes: Int64) async {
        let now = Date()
        var m = metas[key] ?? Meta(totalBytes: bytes, cachedBytes: bytes, complete: true,
                                   lastAccessedAt: now, createdAt: now, rangeMap: ByteRangeMap(),
                                   kind: .artwork)
        m.kind = .artwork
        m.complete = true
        m.cachedBytes = bytes
        m.totalBytes = bytes
        m.lastAccessedAt = now
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: nil)
    }

    public func rangeMap(for key: String) -> ByteRangeMap {
        metas[key]?.rangeMap ?? ByteRangeMap()
    }

    public func totalBytes(for key: String) -> Int64? {
        metas[key]?.totalBytes
    }

    // MARK: - Mutation (driven by the resource loader only)

    public func setContentLength(_ length: Int64, for key: String) {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                    lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        m.totalBytes = length
        metas[key] = m
        persistMeta(key)
    }

    public func recordWrite(range: Range<Int64>, for key: String) async {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                   lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        m.rangeMap.insert(range)
        m.cachedBytes = m.rangeMap.totalBytes()
        if let total = m.totalBytes, m.rangeMap.covers(total: total) {
            m.complete = true
        }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    public func touch(_ key: String) {
        guard var m = metas[key] else { return }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
    }

    public func clearAll() {
        for key in metas.keys {
            try? FileManager.default.removeItem(at: fileURL(for: key))
            try? FileManager.default.removeItem(at: metaURL(key))
            try? FileManager.default.removeItem(at: offlineMetaDir.appendingPathComponent("\(key).json"))
        }
        metas.removeAll()
        pinnedKeys.removeAll()
        persistPinnedKeys()
        for blobDir in [dir, artDir, offlineDir, offlineMetaDir] {
            if let files = try? FileManager.default.contentsOfDirectory(at: blobDir, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// GC partial segments older than 7 days (pinned keys are always kept).
    public func garbageCollectStalePartials() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for (key, m) in metas where !m.complete && m.lastAccessedAt < cutoff && !pinnedKeys.contains(key) {
            remove(key)
        }
    }

    // MARK: - Offline-store migration (RC1, INV-A)

    /// One-time migration of the legacy Caches-based pin store: moves every
    /// pinned blob + meta into the durable offline root, and drops pins whose
    /// blob is already missing (previously purged by the system). Returns the
    /// dropped keys so callers can delete their `download_records` and show the
    /// book as not-downloaded. Idempotent: after the first successful run the
    /// legacy pins file is removed and there is nothing left to migrate.
    @discardableResult
    public func migrateLegacyPinnedBlobs(legacyPinsURL legacyURL: URL? = nil) -> [String] {
        let legacy = legacyURL ?? Self.cacheBaseDirectory()
            .appendingPathComponent("Voxglass/StreamCachePins.json")
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: legacy),
              let keys = try? JSONDecoder().decode([String].self, from: data),
              !keys.isEmpty else {
            return []
        }

        var dropped: [String] = []
        for key in keys {
            let streamingBlob = dir.appendingPathComponent(key)
            let offlineBlob = offlineDir.appendingPathComponent(key)
            if fm.fileExists(atPath: streamingBlob.path) {
                if fm.fileExists(atPath: offlineBlob.path) {
                    try? fm.removeItem(at: streamingBlob)
                } else {
                    try? fm.moveItem(at: streamingBlob, to: offlineBlob)
                }
                let streamingMeta = metaDir.appendingPathComponent("\(key).json")
                let offlineMeta = offlineMetaDir.appendingPathComponent("\(key).json")
                if fm.fileExists(atPath: streamingMeta.path) {
                    try? fm.removeItem(at: offlineMeta)
                    try? fm.moveItem(at: streamingMeta, to: offlineMeta)
                }
                pinnedKeys.insert(key)
            } else {
                // The system already purged this download; drop the pin so the
                // UI stops claiming it is cached.
                let streamingMeta = metaDir.appendingPathComponent("\(key).json")
                if fm.fileExists(atPath: streamingMeta.path) {
                    try? fm.removeItem(at: streamingMeta)
                }
                let offlineMeta = offlineMetaDir.appendingPathComponent("\(key).json")
                if fm.fileExists(atPath: offlineMeta.path) {
                    try? fm.removeItem(at: offlineMeta)
                }
                metas.removeValue(forKey: key)
                pinnedKeys.remove(key)
                dropped.append(key)
            }
        }
        persistPinnedKeys()
        try? fm.removeItem(at: legacy)
        return dropped
    }

    // MARK: - Eviction

    private func evictToFit(protecting protectedKey: String?) async {
        guard limitBytes > 0 else { return }
        // Pinned (offline) bytes are excluded from the streaming budget.
        var total = metas
            .filter { !pinnedKeys.contains($0.key) }
            .values.reduce(0) { $0 + $1.cachedBytes }
        guard total > limitBytes else { return }
        let candidates = metas
            .filter { $0.key != protectedKey && !pinnedKeys.contains($0.key) }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (key, m) in candidates {
            if total <= limitBytes { break }
            remove(key)
            total -= m.cachedBytes
        }
    }

    private func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
        try? FileManager.default.removeItem(at: metaURL(key))
        try? FileManager.default.removeItem(at: offlineMetaDir.appendingPathComponent("\(key).json"))
        metas.removeValue(forKey: key)
    }

    private func discardCachedBytes(for key: String, unpin: Bool) {
        let wasPinned = pinnedKeys.contains(key)
        try? FileManager.default.removeItem(at: fileURL(for: key))
        guard var meta = metas[key] else {
            if unpin {
                pinnedKeys.remove(key)
                persistPinnedKeys()
            }
            return
        }

        meta.cachedBytes = 0
        meta.complete = false
        meta.rangeMap = ByteRangeMap()
        meta.lastAccessedAt = Date()
        metas[key] = meta

        if unpin {
            pinnedKeys.remove(key)
            persistPinnedKeys()
        }
        if wasPinned && unpin {
            try? FileManager.default.removeItem(at: offlineMetaDir.appendingPathComponent("\(key).json"))
        }
        persistMeta(key)
    }

    // MARK: - Persistence

    private static func debugJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func metaURL(_ key: String) -> URL {
        let base = pinnedKeys.contains(key) ? offlineMetaDir : metaDir
        return base.appendingPathComponent("\(key).json")
    }

    private func persistMeta(_ key: String) {
        guard let m = metas[key],
              let data = try? Self.debugJSONEncoder().encode(m) else { return }
        try? data.write(to: metaURL(key))
    }

    private static func loadMetas(from metaDir: URL, and offlineMetaDir: URL) -> [String: Meta] {
        var result = loadMetas(from: metaDir)
        for (key, meta) in loadMetas(from: offlineMetaDir) {
            result[key] = meta
        }
        return result
    }

    private static func loadMetas(from metaDir: URL) -> [String: Meta] {
        var result: [String: Meta] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: metaDir,
                                                                       includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let m = try? JSONDecoder().decode(Meta.self, from: data) {
                result[key] = m
            }
        }
        return result
    }

    // MARK: - Pinned-key persistence

    private func persistPinnedKeys() {
        guard let data = try? Self.debugJSONEncoder().encode(Array(pinnedKeys)) else { return }
        try? data.write(to: pinsURL)
    }

    private static func loadPinnedKeys(from pinsURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: pinsURL),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(keys)
    }
}
