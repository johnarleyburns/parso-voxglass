import Foundation
import SwiftUI
import Combine
import WatchKit
import WidgetKit
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
    /// Read-only progress for complete audio chapter files pushed by the iPhone.
    @Published private(set) var downloads: [WatchBookID: WatchBookDownload] = [:]
    @Published private(set) var listened: [String: WatchListenedRecord] = [:]
    @Published var error: String?
    private let playbackEngine: WatchPlaybackEngine
    private var cancellables = Set<AnyCancellable>()
    private var lastListenedSave = Date.distantPast
    private var lastWidgetState: WatchContinueListeningState?
    private var lastWidgetSave = Date.distantPast
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
        playbackEngine.streamingAllowed = { false }
        session.$snapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.books = snapshot.books }
            .store(in: &cancellables)
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$bookReports
            .receive(on: RunLoop.main)
            .sink { [weak self] reports in
                guard let self else { return }
                self.downloaded = Set(reports.values.filter(\.complete).map(\.bookID))
                self.downloading = Set(reports.values.filter { !$0.complete }.map(\.bookID))
                self.downloads = Dictionary(uniqueKeysWithValues: reports.values.filter { !$0.complete }.map { report in
                    let total = self.books.first { $0.id == report.bookID }?.chapters.count ?? 0
                    return (report.bookID, WatchBookDownload(done: report.installedChapterIDs?.count ?? 0,
                        total: total, state: .sendingFromPhone))
                })
            }
            .store(in: &cancellables)
    }

    var isConnected: Bool { session.isReachable }

    /// Library rows (H2): sorted by last listened, then title.
    var visibleBooks: [WatchBookDTO] {
        let base = books.filter { downloaded.contains($0.id) }
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
        downloaded = Set(session.bookReports.values.filter(\.complete).map(\.bookID))
        // A seeded UI-test launch starts with no listening history, so every run sees the same Home.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSeed") {
            UserDefaults.standard.removeObject(forKey: Self.listenedKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.listenedKey),
           let decoded = try? JSONDecoder().decode([String: WatchListenedRecord].self, from: data) {
            listened = decoded
        }
        books = session.snapshot?.books ?? []
        lastWidgetState = WatchContinueListeningStore.load()
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
        defer { publishWidget() }
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

    // MARK: - Smart Stack (A2)

    /// Writes the "Continue listening" card's state to the App Group. The widget reloads only when
    /// what it shows changes (book, chapter, play state, a minute of time left) — never per tick.
    private func publishWidget() {
        guard let book = heroBook else { return }
        let isCurrent = playbackBook?.id == book.id
        let index = resumeChapterIndex(for: book)
        let state = WatchContinueListeningState(
            bookTitle: book.title, chapterIndex: index,
            chapterTitle: book.chapters.indices.contains(index) ? book.chapters[index].title : "",
            progress: progress(for: book), remainingInBook: remainingInBook(for: book),
            isPlaying: isCurrent && playback.isActuallyPlaying, anchorDate: Date())
        let structural = state.differsStructurally(from: lastWidgetState)
        guard structural || Date().timeIntervalSince(lastWidgetSave) > 30 else { return }
        WatchContinueListeningStore.save(state)
        lastWidgetSave = Date()
        lastWidgetState = state
        if structural { WidgetCenter.shared.reloadTimelines(ofKind: "VoxglassWatchContinueListening") }
    }

    // MARK: - Transport

    func play(_ book: WatchBookDTO, chapterIndex: Int = 0) {
        guard !book.chapters.isEmpty else { error = String(localized: "No playable chapters."); return }
        let index = min(max(0, chapterIndex), book.chapters.count - 1)
        playbackEngine.play(book, chapterIndex: index, allowsStreaming: false)
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

    // Audio is selected and transferred on the phone only. This watch keeps local playback
    // positions, speed, sleep timers and narration features; it never fetches chapter URLs.
}
