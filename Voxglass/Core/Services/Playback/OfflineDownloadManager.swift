import Foundation
import ParsoAudioStreaming

/// Per-book offline availability state (§7).
public enum OfflineState: Equatable {
    case notCached
    case downloading(progress: Double)
    case cached
    case failed
}

/// Result of asking to make a book available offline — lets the UI decide
/// whether to present the cellular prompt before anything starts.
public enum OfflineStartDecision: Equatable {
    case start
    case needsCellularConfirmation
}

/// Downloads every chapter of a book into the streaming cache as *pinned*
/// (never-evicted) complete files, using a background `URLSession` so downloads
/// continue when the app is suspended and survive relaunch.
/// Cellular is gated by the §5 "Cache full books on cellular data" toggle.
@MainActor
public final class OfflineDownloadManager: NSObject, ObservableObject {
    public static let sessionIdentifier = "guru.parso.voxglass.offline"

    /// The active manager, so the `UIApplicationDelegate` background-events hook
    /// can forward the system completion handler.
    public static weak var current: OfflineDownloadManager?

    @Published public private(set) var state: [UUID: OfflineState] = [:]

    private let repository: LibraryRepository
    private let cacheStore: SparseCacheStore
    private let defaults: UserDefaults
    private let taskRegistryKey = "voxglass.offline.taskRegistry.v1"
    private lazy var session: URLSession = makeSession()

    private var chapterFractions: [UUID: [UUID: Double]] = [:]  // bookID -> chapterID -> 0...1
    private var plannedCount: [UUID: Int] = [:]                 // bookID -> chapters in job
    private var failedBooks: Set<UUID> = []
    private var cancelledTaskIdentifiers: Set<Int> = []
    private var taskRegistry: [Int: TaskInfo]
    private var backgroundCompletionHandler: (() -> Void)?

    public init(
        repository: LibraryRepository,
        cacheStore: SparseCacheStore = AudioCache.shared,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.cacheStore = cacheStore
        self.defaults = defaults
        if let data = defaults.data(forKey: taskRegistryKey),
           let stored = try? JSONDecoder().decode([Int: TaskInfo].self, from: data) {
            self.taskRegistry = stored
        } else {
            self.taskRegistry = [:]
        }
        super.init()
        Self.current = self
        _ = session   // eagerly reconnect the background session on launch
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true   // the §5 toggle gates whether we start, not the transport
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Pure decision helpers (testable)

    public static func startDecision(
        isCellular: Bool,
        cacheOnCellular: Bool,
        allowCellularOverride: Bool
    ) -> OfflineStartDecision {
        if isCellular && !cacheOnCellular && !allowCellularOverride {
            return .needsCellularConfirmation
        }
        return .start
    }

    public static func pinCount(states: [UUID: OfflineState]) -> Int {
        states.values.filter { state in
            if case .cached = state { return true }
            if case .downloading = state { return true }
            return false
        }.count
    }

    /// Derives a book's state from per-chapter cache completeness.
    public static func derivedState(chapterComplete: [Bool], anyFailed: Bool) -> OfflineState {
        guard !chapterComplete.isEmpty else { return .notCached }
        if chapterComplete.allSatisfy({ $0 }) { return .cached }
        if anyFailed { return .failed }
        let done = chapterComplete.filter { $0 }.count
        if done == 0 { return .notCached }
        return .downloading(progress: Double(done) / Double(chapterComplete.count))
    }

    // MARK: - Public API

    public func state(for bookID: UUID) -> OfflineState {
        state[bookID] ?? .notCached
    }

    /// Reconstructs each book's state from `download_records` + cache
    /// completeness, and reattaches any in-flight background tasks. Call on launch.
    public func refreshState(for books: [BookWithChapters]) async {
        let allRecords = (try? await repository.fetchAllDownloadRecords()) ?? []
        let recordsByBook = Dictionary(grouping: allRecords, by: \.bookID)
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.book.id, $0) })

        for book in books {
            let records = recordsByBook[book.book.id] ?? []
            let cacheable = cacheableChapters(of: book)
            if !book.chapters.isEmpty,
               book.chapters.allSatisfy({ chapter in
                   guard let url = chapter.resolvedPlayableURL() else { return false }
                   return url.isFileURL && FileManager.default.fileExists(atPath: url.path)
               }) {
                state[book.book.id] = .cached
                continue
            }
            guard !cacheable.isEmpty else {
                state[book.book.id] = .notCached
                continue
            }

            // Only surface an offline state when the user asked for it (a record
            // exists); passive-cache completeness alone does not mark a book cached.
            guard !records.isEmpty else {
                state[book.book.id] = .notCached
                continue
            }

            var completeFlags: [Bool] = []
            var fractions: [UUID: Double] = [:]
            for chapter in cacheable {
                let key = AudioCache.key(for: chapter.url)
                let complete = await cacheStore.isComplete(key)
                completeFlags.append(complete)
                fractions[chapter.chapter.id] = complete ? 1.0 : 0.0
            }
            let anyFailed = records.contains { $0.state == .failed }

            plannedCount[book.book.id] = cacheable.count
            chapterFractions[book.book.id] = fractions
            state[book.book.id] = Self.derivedState(chapterComplete: completeFlags, anyFailed: anyFailed)
        }

        await reattachInFlightTasks(booksByID: booksByID)
    }

    /// Entry point for the "Make available offline" control.
    public func makeAvailableOffline(
        book: BookWithChapters,
        isCellular: Bool,
        allowCellularOverride: Bool = false
    ) async -> OfflineStartDecision {
        let decision = Self.startDecision(
            isCellular: isCellular,
            cacheOnCellular: defaults.bool(forKey: AppPreferencesStore.Keys.cacheFullBooksOnCellular),
            allowCellularOverride: allowCellularOverride
        )
        guard decision == .start else { return decision }
        await startDownload(book: book)
        return .start
    }

    /// Cancels in-flight tasks, unpins + removes the book's cached chapter files,
    /// deletes its download records, and resets state to `.notCached`. Keeps the
    /// book in the library.
    public func removeOffline(book: BookWithChapters) async {
        await cancelTasks(forBookID: book.book.id)
        let cacheable = cacheableChapters(of: book)
        let keys = cacheable.map { AudioCache.key(for: $0.url) }
        if !keys.isEmpty {
            await cacheStore.unpin(keys)
            await cacheStore.remove(keys: keys)
        }
        if let coverURL = book.book.coverURL {
            await cacheStore.unpin([ArtworkCacheKey.key(for: coverURL)])
        }
        try? await repository.deleteDownloadRecords(forBookID: book.book.id)
        chapterFractions[book.book.id] = nil
        plannedCount[book.book.id] = nil
        failedBooks.remove(book.book.id)
        state[book.book.id] = .notCached
    }

    /// Removes every user-requested offline download, including any durable
    /// cache entries that no longer have a matching library record.
    public func removeAllOffline() async {
        await cancelAllTasks()
        let books = (try? await repository.fetchLibrary()) ?? []
        for book in books {
            await removeOffline(book: book)
        }
        let orphanedBookIDs = Set(
            ((try? await repository.fetchAllDownloadRecords()) ?? []).map(\.bookID)
        )
        for bookID in orphanedBookIDs {
            try? await repository.deleteDownloadRecords(forBookID: bookID)
        }
        await cacheStore.clearDurable()
        chapterFractions.removeAll()
        plannedCount.removeAll()
        failedBooks.removeAll()
        state.removeAll()
    }

    /// Stores the system-provided completion handler for background events; the
    /// session calls it once all events have been delivered.
    public func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Start

    private func startDownload(book: BookWithChapters) async {
        let bookID = book.book.id
        failedBooks.remove(bookID)
        if let coverURL = book.book.coverURL {
            let artworkKey = ArtworkCacheKey.key(for: coverURL)
            if await cacheStore.contains(artworkKey) {
                await cacheStore.pin([artworkKey])
            }
        }
        let cacheable = cacheableChapters(of: book)
        guard !cacheable.isEmpty else {
            state[bookID] = .notCached
            return
        }

        plannedCount[bookID] = cacheable.count
        var fractions: [UUID: Double] = [:]
        var records: [DownloadRecord] = []
        var toEnqueue: [(chapter: Chapter, url: URL, key: String)] = []

        for entry in cacheable {
            let key = AudioCache.key(for: entry.url)
            if await cacheStore.isComplete(key) {
                await cacheStore.pin([key])
                fractions[entry.chapter.id] = 1.0
                records.append(record(bookID: bookID, chapterID: entry.chapter.id, state: .complete))
            } else {
                fractions[entry.chapter.id] = 0.0
                records.append(record(bookID: bookID, chapterID: entry.chapter.id, state: .downloading))
                toEnqueue.append((entry.chapter, entry.url, key))
            }
        }

        chapterFractions[bookID] = fractions
        try? await repository.replaceDownloadRecords(records, forBookID: bookID)

        for item in toEnqueue {
            let task = session.downloadTask(with: item.url)
            let info = TaskInfo(bookID: bookID, chapterID: item.chapter.id, key: item.key)
            task.taskDescription = info.encoded
            taskRegistry[task.taskIdentifier] = info
            persistTaskRegistry()
            task.resume()
        }

        updateBookState(bookID)
    }

    // MARK: - Delegate hop handlers (MainActor)

    private func handleProgress(taskIdentifier: Int, taskDescription: String?, fraction: Double) {
        guard let info = taskInfo(taskIdentifier: taskIdentifier, taskDescription: taskDescription) else { return }
        chapterFractions[info.bookID, default: [:]][info.chapterID] = min(max(fraction, 0), 1)
        updateBookState(info.bookID)
    }

    private func handleFinished(taskIdentifier: Int, taskDescription: String?, stagingURL: URL, totalBytes: Int64) async {
        if cancelledTaskIdentifiers.remove(taskIdentifier) != nil {
            try? FileManager.default.removeItem(at: stagingURL)
            taskRegistry[taskIdentifier] = nil
            persistTaskRegistry()
            return
        }
        guard let info = taskInfo(taskIdentifier: taskIdentifier, taskDescription: taskDescription) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            await handleFailure(taskIdentifier: taskIdentifier, taskDescription: taskDescription)
            return
        }
        await cacheStore.ingestCompleteFile(at: stagingURL, key: info.key, totalBytes: totalBytes)
        guard await cacheStore.isComplete(info.key) else {
            // SparseCacheStore intentionally keeps ingestion non-throwing so a
            // cache failure cannot take down playback. Do not let that
            // best-effort behavior turn a missing/corrupt blob into a false
            // completed offline chapter.
            await cacheStore.remove(keys: [info.key])
            await handleFailure(taskIdentifier: taskIdentifier, taskDescription: taskDescription)
            return
        }
        chapterFractions[info.bookID, default: [:]][info.chapterID] = 1.0
        try? await repository.updateDownloadRecord(
            bookID: info.bookID,
            chapterID: info.chapterID,
            state: .complete
        )
        taskRegistry[taskIdentifier] = nil
        persistTaskRegistry()
        updateBookState(info.bookID)
    }

    private func handleFailure(taskIdentifier: Int, taskDescription: String?) async {
        if cancelledTaskIdentifiers.remove(taskIdentifier) != nil {
            taskRegistry[taskIdentifier] = nil
            persistTaskRegistry()
            return
        }
        guard let info = taskInfo(taskIdentifier: taskIdentifier, taskDescription: taskDescription) else { return }
        failedBooks.insert(info.bookID)
        try? await repository.updateDownloadRecord(
            bookID: info.bookID,
            chapterID: info.chapterID,
            state: .failed
        )
        taskRegistry[taskIdentifier] = nil
        persistTaskRegistry()
        state[info.bookID] = .failed
    }

    private func flushBackgroundCompletion() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: - State aggregation

    private func updateBookState(_ bookID: UUID) {
        guard let total = plannedCount[bookID], total > 0 else { return }
        if failedBooks.contains(bookID) {
            state[bookID] = .failed
            return
        }
        let fractions = chapterFractions[bookID] ?? [:]
        let done = fractions.values.filter { $0 >= 1.0 }.count
        if done >= total {
            state[bookID] = .cached
            failedBooks.remove(bookID)
        } else {
            let sum = fractions.values.reduce(0, +)
            state[bookID] = .downloading(progress: min(sum / Double(total), 0.999))
        }
    }

    // MARK: - Task registry / reattach

    private func reattachInFlightTasks(booksByID: [UUID: BookWithChapters]) async {
        let tasks = await allTasks()
        for task in tasks {
            guard let info = taskInfo(taskIdentifier: task.taskIdentifier, taskDescription: task.taskDescription) else { continue }
            if plannedCount[info.bookID] == nil, let book = booksByID[info.bookID] {
                plannedCount[info.bookID] = cacheableChapters(of: book).count
            }
            if task.state == .running || task.state == .suspended {
                if chapterFractions[info.bookID]?[info.chapterID] == nil {
                    chapterFractions[info.bookID, default: [:]][info.chapterID] = 0
                }
                updateBookState(info.bookID)
            }
        }
    }

    private func cancelTasks(forBookID bookID: UUID) async {
        let tasks = await allTasks()
        for task in tasks {
            if let info = taskInfo(taskIdentifier: task.taskIdentifier, taskDescription: task.taskDescription), info.bookID == bookID {
                cancelledTaskIdentifiers.insert(task.taskIdentifier)
                task.cancel()
                taskRegistry[task.taskIdentifier] = nil
            }
        }
        persistTaskRegistry()
    }

    private func cancelAllTasks() async {
        let tasks = await allTasks()
        for task in tasks {
            guard taskInfo(taskIdentifier: task.taskIdentifier, taskDescription: task.taskDescription) != nil else {
                continue
            }
            cancelledTaskIdentifiers.insert(task.taskIdentifier)
            task.cancel()
            taskRegistry[task.taskIdentifier] = nil
        }
        persistTaskRegistry()
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Helpers

    private func persistTaskRegistry() {
        guard let data = try? JSONEncoder().encode(taskRegistry) else { return }
        defaults.set(data, forKey: taskRegistryKey)
    }

    private func taskInfo(taskIdentifier: Int, taskDescription: String?) -> TaskInfo? {
        TaskInfo(taskDescription: taskDescription) ?? taskRegistry[taskIdentifier]
    }

    private struct CacheableChapter {
        let chapter: Chapter
        let url: URL
    }

    private func cacheableChapters(of book: BookWithChapters) -> [CacheableChapter] {
        book.chapters.compactMap { chapter in
            guard let url = ChapterAudioIdentity.canonicalURL(for: chapter),
                  RemoteAudioURL.isCacheable(url) else { return nil }
            return CacheableChapter(chapter: chapter, url: url)
        }
    }

    private func record(bookID: UUID, chapterID: UUID, state: DownloadState) -> DownloadRecord {
        DownloadRecord(
            id: UUID(),
            bookID: bookID,
            chapterID: chapterID,
            state: state,
            localURL: nil,
            bytesDownloaded: 0,
            bytesExpected: nil,
            updatedAt: Date()
        )
    }

    private struct TaskInfo: Codable {
        let bookID: UUID
        let chapterID: UUID
        let key: String

        init(bookID: UUID, chapterID: UUID, key: String) {
            self.bookID = bookID
            self.chapterID = chapterID
            self.key = key
        }

        init?(taskDescription: String?) {
            guard let data = taskDescription?.data(using: .utf8),
                  let info = try? JSONDecoder().decode(TaskInfo.self, from: data) else { return nil }
            self = info
        }

        var encoded: String {
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension OfflineDownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns, so move it synchronously
        // to a staging location the async ingest can consume.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-offline-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            let description = downloadTask.taskDescription
            Task { @MainActor in
                await self.handleFailure(taskIdentifier: downloadTask.taskIdentifier, taskDescription: description)
            }
            return
        }
        let description = downloadTask.taskDescription
        let bytes = max(downloadTask.countOfBytesReceived, downloadTask.response?.expectedContentLength ?? 0)
        Task { @MainActor in
            await self.handleFinished(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: description,
                stagingURL: staging,
                totalBytes: bytes
            )
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let description = downloadTask.taskDescription
        Task { @MainActor in
            self.handleProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                taskDescription: description,
                fraction: fraction
            )
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Success is handled in didFinishDownloadingTo. Ignore cancellations.
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        let description = task.taskDescription
        Task { @MainActor in
            await self.handleFailure(taskIdentifier: task.taskIdentifier, taskDescription: description)
        }
    }

    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.flushBackgroundCompletion()
        }
    }
}
