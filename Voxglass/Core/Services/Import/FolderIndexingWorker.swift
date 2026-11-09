import AVFoundation
import Foundation

/// Failures the indexing worker reports to the service (mapped to user text there).
public enum FolderIndexError: Error, Sendable {
    case unreadableFolder
    case bookmark(String)
}

/// Pure progress coalescer: always emits the first and final update, and spaces
/// intermediate updates at least `minInterval` apart (default 4 updates/second).
public struct ProgressThrottle: Sendable {
    public let minInterval: TimeInterval
    private var lastEmit: Date?

    public init(minInterval: TimeInterval = 0.25) {
        self.minInterval = minInterval
    }

    public mutating func shouldEmit(indexed: Int, total: Int, now: Date) -> Bool {
        let isFinal = indexed >= total
        guard let lastEmit else {
            self.lastEmit = now
            return true
        }
        if isFinal || now.timeIntervalSince(lastEmit) >= minInterval {
            self.lastEmit = now
            return true
        }
        return false
    }
}

/// Performs all non-UI folder indexing work (enumeration, canonicalization,
/// bookmarks, AV duration probing) off the main actor. Security-scoped access is
/// acquired and released inside this worker, around the file I/O it performs.
public actor FolderIndexingWorker {
    public typealias Progress = @Sendable (_ indexed: Int, _ total: Int) async -> Void

    private let maxConcurrency: Int
    private let now: @Sendable () -> Date
    private let minProgressInterval: TimeInterval
    private let startScope: @Sendable (URL) -> Bool
    private let stopScope: @Sendable (URL) -> Void
    private let makeBookmark: @Sendable (URL) throws -> Data
    private let probeDuration: @Sendable (URL) async -> TimeInterval?

    public init(
        maxConcurrency: Int = 3,
        minProgressInterval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> Date = { Date() },
        startScope: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopScope: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        makeBookmark: @escaping @Sendable (URL) throws -> Data = { try $0.bookmarkData() },
        probeDuration: @escaping @Sendable (URL) async -> TimeInterval? = { await FolderIndexingWorker.avDuration(of: $0) }
    ) {
        self.maxConcurrency = max(1, min(maxConcurrency, 4))
        self.minProgressInterval = minProgressInterval
        self.now = now
        self.startScope = startScope
        self.stopScope = stopScope
        self.makeBookmark = makeBookmark
        self.probeDuration = probeDuration
    }

    /// Returns the imports for playable, unknown files in deterministic filename
    /// order. Throws (never returns a partial batch) on error or cancellation.
    public func index(
        folder: URL,
        knownURLs: Set<URL>,
        progress: Progress
    ) async throws -> [LocalAudioImport] {
        let accessing = startScope(folder)
        defer { if accessing { stopScope(folder) } }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw FolderIndexError.unreadableFolder }

        let canonical = contents.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath()
        }
        let audioURLs = FolderWatchService.newAudioFiles(in: canonical, knownURLs: knownURLs)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let total = audioURLs.count
        var throttle = ProgressThrottle(minInterval: minProgressInterval)
        if throttle.shouldEmit(indexed: 0, total: total, now: now()) {
            await progress(0, total)
        }
        guard total > 0 else { return [] }

        let makeBookmark = self.makeBookmark
        let probeDuration = self.probeDuration
        var results = [LocalAudioImport?](repeating: nil, count: total)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, LocalAudioImport).self) { group in
            var next = 0
            func addNext() {
                let index = next
                let url = audioURLs[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let bookmark: Data
                    do { bookmark = try makeBookmark(url) }
                    catch { throw FolderIndexError.bookmark(error.localizedDescription) }
                    let duration = await probeDuration(url)
                    try Task.checkCancellation()
                    return (index, LocalAudioImport(
                        url: url,
                        title: url.deletingPathExtension().lastPathComponent,
                        sortKey: url.lastPathComponent,
                        duration: duration,
                        bookmark: bookmark
                    ))
                }
            }
            for _ in 0..<min(maxConcurrency, total) { addNext() }
            while let (index, item) = try await group.next() {
                results[index] = item
                completed += 1
                if throttle.shouldEmit(indexed: completed, total: total, now: now()) {
                    await progress(completed, total)
                }
                if next < total, !Task.isCancelled { addNext() }
            }
        }

        try Task.checkCancellation()
        let imports = results.compactMap { $0 }
        guard imports.count == total else { throw CancellationError() }
        return imports
    }

    public static func avDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let cm = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(cm)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
