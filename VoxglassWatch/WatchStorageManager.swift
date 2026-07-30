import Foundation
import VoxglassCore

@MainActor
public final class WatchStorageManager: ObservableObject {
    @Published public private(set) var onWatchBooks: [UUID: WatchBookStorageInfo] = [:]
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var totalBookCount: Int = 0

    public var currentBookID: UUID?
    public var onStorageChanged: ((WatchStorageSnapshot) -> Void)?

    private let repository: LibraryRepository
    private let positionStore: SQLitePositionStore
    private let cacheDir: URL

    private var localChapters: [UUID: Set<Int>] = [:]
    private var activeChapterStates: [UUID: WatchChapterStorageInfo] = [:]
    private var lastPlayed: [UUID: Date] = [:]
    private var librarySnapshot: [BookWithChapters] = []

    public init(repository: LibraryRepository, positionStore: SQLitePositionStore) {
        self.repository = repository
        self.positionStore = positionStore
        self.cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voxglass-watch-audio")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func updateLibrary(_ library: [BookWithChapters]) async {
        librarySnapshot = library
        await refresh()
    }

    public func refresh() async {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        var bytes: Int64 = 0
        var fileNameToSize: [String: Int64] = [:]
        for file in files {
            let attrs = (try? file.resourceValues(forKeys: [.fileSizeKey]))
            let size = Int64(attrs?.fileSize ?? 0)
            bytes += size
            fileNameToSize[file.lastPathComponent] = size
        }

        totalBytes = bytes

        let library = await currentLibrary()
        var bookChapters: [UUID: Set<Int>] = [:]
        var bookByteCounts: [UUID: Int64] = [:]
        var storageInfo: [UUID: WatchBookStorageInfo] = [:]

        for bookWithChapters in library {
            let bookID = bookWithChapters.book.id
            let chapters = bookWithChapters.chapters
            var cachedIndices = Set<Int>()
            var cachedBytes: Int64 = 0
            var chapterInfos: [WatchChapterStorageInfo] = []
            var activeProgress: [Double] = []
            var hasFailedChapter = false
            var hasActiveChapter = false

            for chapter in chapters {
                if let active = activeChapterStates[chapter.id] {
                    chapterInfos.append(active)
                    hasActiveChapter = true
                    if case .transferring(let progress) = active.state {
                        activeProgress.append(progress)
                    }
                    if active.state == .failed {
                        hasFailedChapter = true
                    }
                    continue
                }

                if let key = WatchChapterCache.key(for: chapter),
                   let size = fileNameToSize[key] {
                    cachedIndices.insert(chapter.index)
                    cachedBytes += size
                    chapterInfos.append(WatchChapterStorageInfo(
                        id: chapter.id,
                        chapterIndex: chapter.index,
                        state: .available,
                        byteCount: size,
                        bytesExpected: size
                    ))
                } else {
                    chapterInfos.append(WatchChapterStorageInfo(
                        id: chapter.id,
                        chapterIndex: chapter.index,
                        state: .notAvailable
                    ))
                }
            }

            if !cachedIndices.isEmpty {
                bookChapters[bookID] = cachedIndices
                bookByteCounts[bookID] = cachedBytes
            }

            let totalChapterCount = chapters.count
            let completeChapterCount = cachedIndices.count
            let state: WatchTransferState
            if totalChapterCount > 0, completeChapterCount >= totalChapterCount {
                state = .available
            } else if !activeProgress.isEmpty {
                let completedFraction = Double(completeChapterCount)
                let activeFraction = activeProgress.reduce(0, +)
                state = .transferring(progress: min(1, max(0, (completedFraction + activeFraction) / Double(max(totalChapterCount, 1)))))
            } else if hasFailedChapter {
                state = .failed
            } else if completeChapterCount > 0 || hasActiveChapter {
                state = .queued
            } else {
                state = .notAvailable
            }

            if state != .notAvailable {
                storageInfo[bookID] = WatchBookStorageInfo(
                    state: state,
                    byteCount: bookByteCounts[bookID] ?? 0,
                    chapterCount: completeChapterCount,
                    completeChapterCount: completeChapterCount,
                    totalChapterCount: totalChapterCount,
                    chapters: chapterInfos.sorted { $0.chapterIndex < $1.chapterIndex }
                )
            }
        }

        localChapters = bookChapters
        totalBookCount = storageInfo.values.filter { $0.state != .notAvailable }.count
        onWatchBooks = storageInfo
        onStorageChanged?(storageSnapshot())
    }

    public func storageInfo(for bookID: UUID) -> WatchBookStorageInfo {
        onWatchBooks[bookID] ?? WatchBookStorageInfo.notAvailable
    }

    public func chapterStorageInfo(for book: BookWithChapters) -> [WatchChapterStorageInfo] {
        if let info = onWatchBooks[book.book.id], !info.chapters.isEmpty {
            return info.chapters
        }
        return book.chapters.naturallySorted().map {
            WatchChapterStorageInfo(id: $0.id, chapterIndex: $0.index, state: .notAvailable)
        }
    }

    public func storageSnapshot() -> WatchStorageSnapshot {
        WatchStorageSnapshot(books: onWatchBooks)
    }

    public func isAvailableOffline(bookID: UUID) -> Bool {
        onWatchBooks[bookID]?.state == .available
    }

    public func localURL(for chapter: Chapter) -> URL? {
        guard let key = WatchChapterCache.key(for: chapter) else { return nil }
        let fileURL = cacheDir.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    public func deleteOffline(bookID: UUID) async {
        let library = await currentLibrary()
        guard let book = library.first(where: { $0.book.id == bookID }) else { return }
        let chapters = localChapters[bookID] ?? []

        for chapter in book.chapters {
            activeChapterStates.removeValue(forKey: chapter.id)
            if chapters.contains(chapter.index), let key = WatchChapterCache.key(for: chapter) {
                let fileURL = cacheDir.appendingPathComponent(key)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        await refresh()
    }

    public func clearAllCache() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        localChapters = [:]
        activeChapterStates = [:]
        lastPlayed = [:]
        onWatchBooks = [:]
        totalBytes = 0
        totalBookCount = 0
        onStorageChanged?(storageSnapshot())
    }

    public func markPlayed(bookID: UUID) {
        lastPlayed[bookID] = Date()
    }

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

    public func ingestFile(at sourceURL: URL, for chapter: Chapter, bookID: UUID) async {
        guard let key = WatchChapterCache.key(for: chapter) else { return }
        let dest = cacheDir.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: sourceURL, to: dest)

        activeChapterStates.removeValue(forKey: chapter.id)
        var chapters = localChapters[bookID] ?? []
        chapters.insert(chapter.index)
        localChapters[bookID] = chapters

        let attrs = try? dest.resourceValues(forKeys: [.fileSizeKey])
        totalBytes += Int64(attrs?.fileSize ?? 0)

        await refresh()
        await evictIfNeeded()
    }

    public func downloadChapter(_ chapter: Chapter, bookID: UUID) async throws {
        guard let url = WatchChapterCache.canonicalURL(for: chapter),
              let key = WatchChapterCache.key(for: chapter) else { throw URLError(.badURL) }
        let dest = cacheDir.appendingPathComponent(key)

        guard !FileManager.default.fileExists(atPath: dest.path) else {
            await refresh()
            return
        }

        activeChapterStates[chapter.id] = WatchChapterStorageInfo(
            id: chapter.id,
            chapterIndex: chapter.index,
            state: .transferring(progress: 0)
        )
        await refresh()

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            let expected = response.expectedContentLength > 0 ? response.expectedContentLength : -1
            activeChapterStates[chapter.id] = WatchChapterStorageInfo(
                id: chapter.id,
                chapterIndex: chapter.index,
                state: .transferring(progress: 0.95),
                byteCount: max(expected, 0),
                bytesExpected: expected > 0 ? expected : nil
            )
            await refresh()

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            activeChapterStates.removeValue(forKey: chapter.id)
            var chapters = localChapters[bookID] ?? []
            chapters.insert(chapter.index)
            localChapters[bookID] = chapters
            markPlayed(bookID: bookID)
            await refresh()
            await evictIfNeeded()
        } catch {
            activeChapterStates[chapter.id] = WatchChapterStorageInfo(
                id: chapter.id,
                chapterIndex: chapter.index,
                state: .failed
            )
            await refresh()
            throw error
        }
    }

    private func currentLibrary() async -> [BookWithChapters] {
        if !librarySnapshot.isEmpty {
            return librarySnapshot
        }
        return (try? await repository.fetchLibrary()) ?? []
    }
}
