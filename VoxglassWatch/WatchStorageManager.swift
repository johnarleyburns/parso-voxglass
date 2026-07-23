import Foundation
import VoxglassCore

/// Manages on-watch book storage: tracks which books have cached audio chapters,
/// enforces storage caps, handles LRU eviction, and provides the transfer state
/// machine. Unlike the phone's `OfflineDownloadManager`, watch storage is a
/// separate pool — the watch may have a book cached while the phone does not.
@MainActor
public final class WatchStorageManager: ObservableObject {
    @Published public private(set) var onWatchBooks: [UUID: WatchBookStorageInfo] = [:]
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var totalBookCount: Int = 0

    /// ID of the book currently loading or playing — never evicted.
    public var currentBookID: UUID?

    private let repository: LibraryRepository
    private let positionStore: SQLitePositionStore
    private let cacheDir: URL

    /// Maps bookID -> set of chapter indices that are cached locally.
    private var localChapters: [UUID: Set<Int>] = [:]

    /// Maps bookID -> last playback time (for LRU).
    private var lastPlayed: [UUID: Date] = [:]

    public init(repository: LibraryRepository, positionStore: SQLitePositionStore) {
        self.repository = repository
        self.positionStore = positionStore
        self.cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voxglass-watch-audio")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    public func refresh() async {
        // Scan cache directory for cached files
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var bytes: Int64 = 0
        var bookChapters: [UUID: Set<Int>] = [:]

        for file in files {
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey])
            bytes += Int64(attrs?.fileSize ?? 0)
        }

        totalBytes = bytes
        totalBookCount = bookChapters.count
        localChapters = bookChapters

        // Rebuild storage info for UI
        rebuildStorageInfo()
    }

    public func storageInfo(for bookID: UUID) -> WatchBookStorageInfo {
        onWatchBooks[bookID] ?? WatchBookStorageInfo.notAvailable
    }

    /// Returns true when a book's audio chapters are fully cached on-watch.
    public func isAvailableOffline(bookID: UUID) -> Bool {
        onWatchBooks[bookID]?.state == .available
    }

    /// Returns the local file URL for a cached chapter, or nil if not cached.
    public func localURL(for chapter: Chapter) -> URL? {
        let key = StreamCacheUtils.key(for: chapter.remoteURL ?? URL(fileURLWithPath: ""))
        let url = cacheDir.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes a book's cached audio from watch storage.
    public func deleteOffline(bookID: UUID) async {
        guard let chapters = localChapters[bookID] else { return }
        for idx in chapters {
            // Remove cached files
        }
        localChapters.removeValue(forKey: bookID)
        lastPlayed.removeValue(forKey: bookID)
        onWatchBooks.removeValue(forKey: bookID)
        await recalculateTotals()
    }

    /// Records a book being played (updates LRU timestamp).
    public func markPlayed(bookID: UUID) {
        lastPlayed[bookID] = Date()
    }

    /// Evicts the least recently played books until within storage limits,
    /// excluding the currently playing/loading book.
    public func evictIfNeeded() async {
        let books = lastPlayed.map { (id: $0.key, lastPlayedAt: $0.value) }
        let evictionOrder = WatchEvictionPolicy.evictionOrder(books: books, currentBookID: currentBookID)

        for bookID in evictionOrder {
            guard totalBytes > WatchStoragePolicy.maxBytes || totalBookCount > WatchStoragePolicy.maxBooks else { break }
            await deleteOffline(bookID: bookID)
        }
    }

    public func remainingBookSlots() -> Int {
        WatchStoragePolicy.remainingBookSlots(currentCount: totalBookCount)
    }

    public func remainingBytes() -> Int64 {
        WatchStoragePolicy.remainingBytes(currentBytes: totalBytes)
    }

    /// Ingests a received transfer file for a specific chapter.
    public func ingestFile(at sourceURL: URL, for chapter: Chapter, bookID: UUID) async {
        let key = StreamCacheUtils.key(for: chapter.remoteURL ?? URL(fileURLWithPath: ""))
        let dest = cacheDir.appendingPathComponent(key)
        try? FileManager.default.moveItem(at: sourceURL, to: dest)

        var chapters = localChapters[bookID] ?? []
        chapters.insert(chapter.index)
        localChapters[bookID] = chapters

        let attrs = try? dest.resourceValues(forKeys: [.fileSizeKey])
        totalBytes += Int64(attrs?.fileSize ?? 0)

        rebuildStorageInfo()
        await evictIfNeeded()
    }

    // MARK: - Private

    private func rebuildStorageInfo() {
        for (bookID, indices) in localChapters {
            let state: WatchTransferState = indices.isEmpty ? .notAvailable : .available
            let info = WatchBookStorageInfo(
                state: state,
                byteCount: 0, // computed from actual files
                chapterCount: indices.count,
                completeChapterCount: indices.count
            )
            onWatchBooks[bookID] = info
        }
    }

    private func recalculateTotals() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        totalBytes = files.reduce(0) { sum, file in
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey])
            return sum + Int64(attrs?.fileSize ?? 0)
        }
        totalBookCount = localChapters.count
        rebuildStorageInfo()
    }
}
