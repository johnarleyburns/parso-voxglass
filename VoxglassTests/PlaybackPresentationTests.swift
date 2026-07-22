import XCTest
@testable import VoxglassCore

@MainActor
final class PlaybackPresentationTests: XCTestCase {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let store: MemoryPositionStore
        let snapshotStore: LastPlaybackSnapshotStore
        let bridge: NoopPlaybackBridge
    }

    private actor MemoryPositionStore: PositionStore {
        private struct Key: Hashable {
            let bookID: UUID
            let chapterID: UUID
        }

        private var positions: [Key: PlaybackPosition] = [:]

        func save(_ position: PlaybackPosition) async throws {
            positions[Key(bookID: position.bookID, chapterID: position.chapterID)] = position
        }

        func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? {
            positions[Key(bookID: bookID, chapterID: chapterID)]
        }

        func latestPosition() async throws -> PlaybackPosition? {
            positions.values.max { $0.updatedAt < $1.updatedAt }
        }

        func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? {
            positions.values
                .filter { $0.bookID == bookID }
                .max { $0.updatedAt < $1.updatedAt }
        }
    }

    private func makeHarness() -> Harness {
        let engine = FakeAudioEngine()
        let store = MemoryPositionStore()
        let defaults = UserDefaults(suiteName: "presentation-\(UUID().uuidString)")!
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        return Harness(
            coordinator: coordinator,
            engine: engine,
            store: store,
            snapshotStore: snapshotStore,
            bridge: bridge
        )
    }

    private func makeBook(title: String = "Book", chapters count: Int = 3) -> BookWithChapters {
        let bookID = UUID()
        let chapters = (0..<count).map { index in
            Chapter(
                bookID: bookID,
                title: "Chapter \(index)",
                index: index,
                duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        return BookWithChapters(
            book: Book(id: bookID, title: title, authors: ["A"], sourceID: UUID()),
            chapters: chapters
        )
    }

    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func isForbiddenPresentationEffect(_ call: FakeAudioEngine.Call) -> Bool {
        if case .load = call { return true }
        if case .play = call { return true }
        if case .preloadNext = call { return true }
        if case .prefetchIntoCache = call { return true }
        return false
    }

    func testPresentBookCreatesPausedSessionAtResolvedResumePosition() async throws {
        let h = makeHarness()
        let book = makeBook()
        let chapter = book.chapters[1]
        try await h.store.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: chapter.id,
            position: 40,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 300)
        ))
        h.snapshotStore.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: chapter.id,
            position: 73,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 100)
        ))

        await h.coordinator.present(book)

        XCTAssertEqual(h.coordinator.currentSession?.book.id, book.book.id)
        XCTAssertEqual(h.coordinator.currentSession?.chapter.id, chapter.id)
        XCTAssertEqual(h.coordinator.currentSession?.position ?? -1, 73, accuracy: 0.001)
        XCTAssertEqual(h.coordinator.currentSession?.isPlaying, false)
        XCTAssertEqual(h.bridge.lastNowPlaying?.elapsed ?? -1, 73, accuracy: 0.001)
        XCTAssertEqual(h.bridge.lastNowPlaying?.reportedRate ?? -1, 0)
    }

    func testPresentBookDoesNotLoadPlayWarmCacheOrPreload() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.reset()

        await h.coordinator.present(book)

        let forbidden = h.engine.calls.filter(isForbiddenPresentationEffect)
        XCTAssertTrue(forbidden.isEmpty, "Paused presentation must not touch playback or warmup effects: \(forbidden)")
    }

    func testToggleAfterPresentLoadsOnceAtPresentedOffsetAndStartsPlayback() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: book.chapters[1].id,
            position: 42,
            duration: 100
        ))
        await h.coordinator.present(book)
        h.engine.reset()

        h.coordinator.togglePlayPause()
        await drainMainQueue()

        XCTAssertEqual(h.engine.loadCalls.count, 1)
        XCTAssertEqual(h.engine.loadCalls.first?.url, book.chapters[1].localURL)
        XCTAssertEqual(h.engine.loadCalls.first?.startTime ?? -1, 42, accuracy: 0.001)
        XCTAssertTrue(h.engine.calls.contains(.play))
        XCTAssertEqual(h.coordinator.currentSession?.isPlaying, true)
    }

    func testPresentRequestedChapterUsesSavedChapterPositionOrZero() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: book.chapters[2].id,
            position: 66,
            duration: 100
        ))

        await h.coordinator.present(book, chapter: book.chapters[2])

        XCTAssertEqual(h.coordinator.currentSession?.chapter.id, book.chapters[2].id)
        XCTAssertEqual(h.coordinator.currentSession?.position ?? -1, 66, accuracy: 0.001)
        XCTAssertEqual(h.coordinator.currentSession?.isPlaying, false)

        await h.coordinator.present(book, chapter: book.chapters[0])

        XCTAssertEqual(h.coordinator.currentSession?.chapter.id, book.chapters[0].id)
        XCTAssertEqual(h.coordinator.currentSession?.position ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(h.coordinator.currentSession?.isPlaying, false)
    }

    func testPresentDifferentBookOverwritesSessionAndNextToggleReloadsNewBook() async {
        let h = makeHarness()
        let first = makeBook(title: "First")
        let second = makeBook(title: "Second")
        await h.coordinator.play(first)
        h.engine.currentTime = 31
        h.coordinator.pause()
        h.engine.reset()

        await h.coordinator.present(second)

        XCTAssertEqual(h.coordinator.currentSession?.book.id, second.book.id)
        XCTAssertEqual(h.coordinator.currentSession?.isPlaying, false)
        XCTAssertFalse(h.engine.isPlaying)

        h.engine.reset()
        h.coordinator.togglePlayPause()
        await drainMainQueue()

        XCTAssertEqual(h.engine.loadCalls.count, 1)
        XCTAssertEqual(h.engine.loadCalls.first?.url, second.chapters[0].localURL)
        XCTAssertTrue(h.engine.calls.contains(.play))
    }
}
