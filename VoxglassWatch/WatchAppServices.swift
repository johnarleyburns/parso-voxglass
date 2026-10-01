import Foundation
import SwiftUI
import Combine
import WatchKit
import VoxglassWatchProtocol
import VoxglassWatchCore

/// Where a book was last listened to — drives the Home hero, library sort ("last listened") and
/// each row's progress (watch redesign H1/H2). Stored locally; positions themselves stay in
/// `WatchPlaybackPositionStore`.
struct WatchListenedRecord: Codable, Equatable {
    var chapterIndex: Int
    var position: TimeInterval
    var date: Date
}

@MainActor
final class WatchAppServices: ObservableObject {
    static let shared = WatchAppServices()
    let session = WatchSessionAdapter.shared
    @Published private(set) var books: [WatchBookDTO] = []
    @Published private(set) var downloaded = Set<WatchBookID>()
    @Published private(set) var downloading = Set<WatchBookID>()
    @Published private(set) var playbackBook: WatchBookDTO?
    @Published private(set) var playback = WatchPlaybackSnapshot()
    @Published private(set) var volume: Double = 1
    /// §5 C3 — the armed sleep timer and its seconds remaining, for the chip and the list.
    @Published private(set) var sleepTimer: WatchSleepTimer?
    @Published private(set) var sleepRemaining: TimeInterval?
    /// §5 D1 — downloads the watch is doing itself (with pause/stop) and ones the iPhone is pushing.
    @Published private(set) var downloads: [WatchBookID: WatchBookDownload] = [:]
    @Published private(set) var listened: [String: WatchListenedRecord] = [:]
    @Published var error: String?
    private let playbackEngine: WatchPlaybackEngine
    private var cancellables = Set<AnyCancellable>()
    private var downloadTasks: [WatchBookID: Task<Void, Never>] = [:]
    private var pausedDownloads = Set<WatchBookID>()
    private var lastListenedSave = Date.distantPast
    private static let listenedKey = "watch.listened"

    private init() {
        let smoke = ProcessInfo.processInfo.arguments.contains("-uiTestSeed")
            || ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_ALICE"] == "1"
        playbackEngine = WatchPlaybackEngine(
            smokeMode: smoke,
            smokeFailure: ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_PLAYBACK_FAILURE"] == "1"
        )
        playbackEngine.onSnapshot = { [weak self] snapshot in self?.applyPlayback(snapshot) }
        playbackEngine.onBookChanged = { [weak self] book in self?.playbackBook = book }
        playbackEngine.onSleepChange = { [weak self] timer, remaining in
            self?.sleepTimer = timer
            self?.sleepRemaining = remaining
        }
        playbackEngine.streamingAllowed = { [weak self] in self?.isConnected ?? false }
        session.$snapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.books = snapshot.books }
            .store(in: &cancellables)
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$requestedDownloadBookID
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] bookID in
                guard let self, let book = self.books.first(where: { $0.id == bookID }) else { return }
                self.startDownload(book, notifyPhone: false)
            }
            .store(in: &cancellables)
        session.$phoneTransferProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self else { return }
                for (bookID, entry) in progress where self.downloadTasks[bookID] == nil {
                    self.downloads[bookID] = WatchBookDownload(done: entry.done, total: entry.total,
                                                               state: .sendingFromPhone)
                }
            }
            .store(in: &cancellables)
        session.$completedFileTransfer
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] completion in
                guard let self, let book = self.books.first(where: { $0.id == completion.bookID }) else { return }
                self.markDownloaded(book.id)
                self.downloading.remove(completion.bookID)
                self.downloads.removeValue(forKey: completion.bookID)
                self.session.reportDownload(book: book, bytes: completion.bytes, complete: true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .watchRemoveDownloadedBook)
            .compactMap { $0.object as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] rawID in
                guard let self, let book = self.books.first(where: { $0.id.rawValue == rawID }) else { return }
                self.remove(book)
            }
            .store(in: &cancellables)
    }

    var isConnected: Bool { session.isReachable }

    /// Library rows (H2): sorted by last listened, then title.
    var visibleBooks: [WatchBookDTO] {
        let base = isConnected ? books : books.filter { downloaded.contains($0.id) }
        return base.sorted { lhs, rhs in
            let l = listened[lhs.id.rawValue]?.date ?? .distantPast
            let r = listened[rhs.id.rawValue]?.date ?? .distantPast
            if l != r { return l > r }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// The Home hero's book (H1): the one loaded now, else the most recently listened.
    var heroBook: WatchBookDTO? {
        if let playbackBook { return playbackBook }
        return visibleBooks.first { listened[$0.id.rawValue] != nil }
    }

    func bootstrap() {
        downloaded = Set(UserDefaults.standard.stringArray(forKey: "watch.downloaded")?.map(WatchBookID.init) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.listenedKey),
           let decoded = try? JSONDecoder().decode([String: WatchListenedRecord].self, from: data) {
            listened = decoded
        }
        books = session.snapshot?.books ?? []
        session.refresh()
    }

    // MARK: - Progress (H1/H2)

    func progress(for book: WatchBookDTO) -> Double {
        if playbackBook?.id == book.id {
            return WatchBookTime.bookProgress(chapterDurations: book.chapters.map(\.duration),
                                              chapterIndex: playback.chapterIndex, position: playback.position)
        }
        guard let record = listened[book.id.rawValue] else { return 0 }
        return WatchBookTime.bookProgress(chapterDurations: book.chapters.map(\.duration),
                                          chapterIndex: record.chapterIndex, position: record.position)
    }

    func remainingInBook(for book: WatchBookDTO) -> TimeInterval {
        let durations = book.chapters.map(\.duration)
        if playbackBook?.id == book.id {
            return WatchBookTime.remainingInBook(chapterDurations: durations, chapterIndex: playback.chapterIndex,
                                                 position: playback.position, rate: playback.rate)
        }
        let record = listened[book.id.rawValue]
        return WatchBookTime.remainingInBook(chapterDurations: durations, chapterIndex: record?.chapterIndex ?? 0,
                                             position: record?.position ?? 0, rate: 1)
    }

    /// The chapter a "Resume" button would continue from.
    func resumeChapterIndex(for book: WatchBookDTO) -> Int {
        if playbackBook?.id == book.id { return playback.chapterIndex }
        return min(max(0, listened[book.id.rawValue]?.chapterIndex ?? 0), max(0, book.chapters.count - 1))
    }

    func resumePosition(for book: WatchBookDTO) -> TimeInterval? {
        if playbackBook?.id == book.id { return playback.position }
        return listened[book.id.rawValue]?.position
    }

    private func applyPlayback(_ snapshot: WatchPlaybackSnapshot) {
        let previousPhase = playback.phase
        playback = snapshot
        guard let bookID = snapshot.bookID, snapshot.chapterIndex >= 0 else { return }
        let phaseChanged = previousPhase != snapshot.phase
        guard phaseChanged || Date().timeIntervalSince(lastListenedSave) > 10 else { return }
        lastListenedSave = Date()
        listened[bookID.rawValue] = WatchListenedRecord(chapterIndex: snapshot.chapterIndex,
                                                        position: snapshot.position, date: Date())
        if let data = try? JSONEncoder().encode(listened) {
            UserDefaults.standard.set(data, forKey: Self.listenedKey)
        }
    }

    // MARK: - Transport

    func play(_ book: WatchBookDTO, chapterIndex: Int = 0) {
        guard !book.chapters.isEmpty else { error = String(localized: "No playable chapters."); return }
        let index = min(max(0, chapterIndex), book.chapters.count - 1)
        playbackEngine.play(book, chapterIndex: index, allowsStreaming: isConnected)
    }
    func togglePlayPause() { playbackEngine.togglePlayPause() }
    func nextChapter() { playbackEngine.nextChapter() }
    func previousChapter() { playbackEngine.previousChapter() }
    func jump(toChapter index: Int) {
        guard let book = playbackBook else { return }
        if playback.bookID == book.id { playbackEngine.jump(toChapter: index) } else { play(book, chapterIndex: index) }
    }
    func skip(by delta: TimeInterval) { playbackEngine.skip(by: delta) }
    func retryPlayback() { playbackEngine.retry() }
    func seek(to position: TimeInterval) { playbackEngine.seek(to: position) }
    func setRate(_ rate: Double) { playbackEngine.setRate(rate) }
    func setVolume(_ value: Double) {
        playbackEngine.setVolume(value)
        volume = playbackEngine.volume
    }
    func setSleepTimer(_ mode: WatchSleepTimer.Mode?) { playbackEngine.setSleepTimer(mode) }
    func persistPlaybackPosition() { playbackEngine.persistPlaybackPosition() }

    // MARK: - Downloads (§5 D1)

    func download(_ book: WatchBookDTO) {
        startDownload(book, notifyPhone: true)
    }

    func pauseDownload(_ book: WatchBookDTO) {
        pausedDownloads.insert(book.id)
        downloadTasks[book.id]?.cancel()
        downloadTasks[book.id] = nil
        downloading.remove(book.id)
        if var entry = downloads[book.id] { entry.state = .paused; downloads[book.id] = entry }
    }

    func resumeDownload(_ book: WatchBookDTO) {
        pausedDownloads.remove(book.id)
        startDownload(book, notifyPhone: false)
    }

    /// Stop and remove: cancels the watch's own download and deletes this book's audio here.
    func stopDownload(_ book: WatchBookDTO) {
        pausedDownloads.remove(book.id)
        downloadTasks[book.id]?.cancel()
        downloadTasks[book.id] = nil
        downloading.remove(book.id)
        downloads.removeValue(forKey: book.id)
        deleteAudio(for: book.id)
        remove(book)
        session.reportDownload(book: book, bytes: 0, complete: false)
    }

    private func startDownload(_ book: WatchBookDTO, notifyPhone: Bool) {
        guard downloadTasks[book.id] == nil else { return }
        if notifyPhone {
            session.requestDownload(for: book)
        }
        downloading.insert(book.id)
        downloadTasks[book.id] = Task { [weak self] in
            await self?.downloadApprovedChapters(for: book)
            self?.downloadTasks[book.id] = nil
        }
    }

    func remove(_ book: WatchBookDTO) {
        downloaded.remove(book.id)
        UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "watch.downloaded")
    }

    private func markDownloaded(_ id: WatchBookID) {
        downloaded.insert(id)
        UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "watch.downloaded")
        WKInterfaceDevice.current().play(.success)
    }

    private func bookRoot(_ id: WatchBookID) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("DownloadedBooks/\(id.rawValue)", isDirectory: true)
    }

    private func deleteAudio(for id: WatchBookID) {
        guard let root = try? bookRoot(id) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private func downloadApprovedChapters(for book: WatchBookDTO) async {
        let urls = book.chapters.compactMap(\.approvedStreamURL)
        guard urls.count == book.chapters.count, !urls.isEmpty else {
            downloading.remove(book.id)
            // Not an error: the iPhone transfers this book (or hasn't approved it yet). Say so.
            if downloads[book.id] == nil {
                downloads[book.id] = WatchBookDownload(done: 0, total: book.chapters.count, state: .waitingForPhone)
            }
            return
        }
        do {
            let root = try bookRoot(book.id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var bytes: Int64 = 0
            var done = 0
            downloads[book.id] = WatchBookDownload(done: 0, total: book.chapters.count, state: .downloading)
            for (chapter, url) in zip(book.chapters, urls) {
                try Task.checkCancellation()
                let destination = root.appendingPathComponent(chapter.durableFilename)
                // Resume after Pause: chapters already on disk are kept, not fetched again.
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let (temporary, _) = try await URLSession.shared.download(from: url)
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                bytes += Int64((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0)
                done += 1
                downloads[book.id] = WatchBookDownload(done: done, total: book.chapters.count, state: .downloading)
            }
            markDownloaded(book.id)
            downloads.removeValue(forKey: book.id)
            session.reportDownload(book: book, bytes: bytes, complete: true)
        } catch is CancellationError {
            // Paused or stopped: the state was already set by the caller.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same as above for an in-flight URLSession task.
        } catch {
            let message = String(localized: "Download failed: \(error.localizedDescription)")
            downloads[book.id] = WatchBookDownload(done: downloads[book.id]?.done ?? 0, total: book.chapters.count,
                                                   state: .failed(message))
            session.reportDownload(book: book, bytes: 0, complete: false)
        }
        downloading.remove(book.id)
    }
}
