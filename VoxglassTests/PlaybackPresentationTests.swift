import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite(.serialized) struct PlaybackPresentationTests {

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

    /// Waits for an async effect to land instead of sleeping a fixed duration;
    /// see `MiniplayerRestoreTests.waitUntil` for the rationale.
    private func waitUntil(_ condition: () -> Bool, timeoutNanoseconds: UInt64 = 5_000_000_000) async -> Bool {
        var waited: UInt64 = 0
        let step: UInt64 = 20_000_000
        while waited < timeoutNanoseconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        return condition()
    }

    private func isForbiddenPresentationEffect(_ call: FakeAudioEngine.Call) -> Bool {
        if case .load = call { return true }
        if case .play = call { return true }
        if case .preloadNext = call { return true }
        if case .prefetchIntoCache = call { return true }
        return false
    }

    @Test func presentBookCreatesPausedSessionAtResolvedResumePosition() async throws {
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

        #expect(h.coordinator.currentSession?.book.id == book.book.id)
        #expect(h.coordinator.currentSession?.chapter.id == chapter.id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (73)) <= 0.001)
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(abs((h.bridge.lastNowPlaying?.elapsed ?? -1) - (73)) <= 0.001)
        #expect(h.bridge.lastNowPlaying?.reportedRate ?? -1 == 0)
    }

    @Test func presentBookDoesNotLoadPlayWarmCacheOrPreload() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.reset()

        await h.coordinator.present(book)

        let forbidden = h.engine.calls.filter(isForbiddenPresentationEffect)
        #expect(forbidden.isEmpty)  // Paused presentation must not touch playback or warmup effects: \(forbidden)
    }

    @Test func toggleAfterPresentLoadsOnceAtPresentedOffsetAndStartsPlayback() async throws {
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
        await waitUntil { h.coordinator.currentSession?.isPlaying == true }

        #expect(h.engine.loadCalls.count == 1)
        #expect(h.engine.loadCalls.first?.url == book.chapters[1].localURL)
        #expect(abs((h.engine.loadCalls.first?.startTime ?? -1) - (42)) <= 0.001)
        #expect(h.engine.calls.contains(.play))
        #expect(h.coordinator.currentSession?.isPlaying == true)
    }

    @Test func presentRequestedChapterUsesSavedChapterPositionOrZero() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: book.chapters[2].id,
            position: 66,
            duration: 100
        ))

        await h.coordinator.present(book, chapter: book.chapters[2])

        #expect(h.coordinator.currentSession?.chapter.id == book.chapters[2].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (66)) <= 0.001)
        #expect(h.coordinator.currentSession?.isPlaying == false)

        await h.coordinator.present(book, chapter: book.chapters[0])

        #expect(h.coordinator.currentSession?.chapter.id == book.chapters[0].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (0)) <= 0.001)
        #expect(h.coordinator.currentSession?.isPlaying == false)
    }

    @Test func presentDifferentBookOverwritesSessionAndNextToggleReloadsNewBook() async {
        let h = makeHarness()
        let first = makeBook(title: "First")
        let second = makeBook(title: "Second")
        await h.coordinator.play(first)
        h.engine.currentTime = 31
        h.coordinator.pause()
        h.engine.reset()

        await h.coordinator.present(second)

        #expect(h.coordinator.currentSession?.book.id == second.book.id)
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(!(h.engine.isPlaying))

        h.engine.reset()
        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(h.engine.loadCalls.count == 1)
        #expect(h.engine.loadCalls.first?.url == second.chapters[0].localURL)
        #expect(h.engine.calls.contains(.play))
    }
}
