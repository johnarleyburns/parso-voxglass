import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite(.serialized) struct PlaybackCoordinatorOwnershipTests {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let snapshotStore: LastPlaybackSnapshotStore
    }

    private actor EmptyPositionStore: PositionStore {
        func save(_ position: PlaybackPosition) async throws {}
        func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? { nil }
        func latestPosition() async throws -> PlaybackPosition? { nil }
        func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? { nil }
    }

    private func makeHarness() -> Harness {
        let engine = FakeAudioEngine()
        let defaults = UserDefaults(suiteName: "own-\(UUID().uuidString)")!
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: EmptyPositionStore(),
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: NoopPlaybackBridge()
        )
        return Harness(coordinator: coordinator, engine: engine, snapshotStore: snapshotStore)
    }

    private func makeBook(title: String) -> BookWithChapters {
        let bookID = UUID()
        let chapters = (0..<2).map { index in
            Chapter(
                bookID: bookID, title: "Chapter \(index)", index: index, duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        return BookWithChapters(book: Book(id: bookID, title: title, authors: ["A"], sourceID: UUID()), chapters: chapters)
    }

    private func drain() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func presentUnloaded(_ h: Harness, _ book: BookWithChapters) async {
        h.snapshotStore.save(PlaybackPosition(
            bookID: book.book.id, chapterID: book.chapters[0].id,
            position: 30, duration: 100, updatedAt: Date(), isFinished: false
        ))
        await h.coordinator.restorePresentedSession(from: [book])
    }

    private var playCount: (FakeAudioEngine) -> Int {
        { $0.calls.filter { $0 == .play }.count }
    }

    @Test func staleInitialLoadCannotOverrideNewerSelection() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(a)
        await drain()
        h.coordinator.selectAndPlay(b)
        await drain()
        h.engine.resumeSuspendedLoad() // A (stale)
        await drain()
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // B
        await drain()
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(playCount(h.engine) == 1)
    }

    @Test func staleResumeCannotPlayAfterNewSelection() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        await presentUnloaded(h, a)
        h.engine.suspendLoads = true
        h.coordinator.togglePlayPause()
        await drain()
        h.coordinator.selectAndPlay(b)
        await drain()
        h.engine.resumeSuspendedLoad() // A's lazy load
        await drain()
        #expect(playCount(h.engine) == 0)
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .preparing)
        h.engine.resumeSuspendedLoad() // B
        await drain()
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(playCount(h.engine) == 1)
    }

    @Test func rapidSelectionLeavesLastSelectionAsOnlyOwner() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B"), c = makeBook(title: "C")
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(a)
        await drain()
        h.coordinator.selectAndPlay(b)
        await drain()
        h.coordinator.selectAndPlay(c)
        await drain()
        h.engine.resumeSuspendedLoad() // A
        h.engine.resumeSuspendedLoad() // B
        await drain()
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // C
        await drain()
        #expect(h.coordinator.currentSession?.book.id == c.book.id)
        #expect(playCount(h.engine) == 1)
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func pauseDuringLoadPreventsSurpriseAutoplay() async {
        let h = makeHarness()
        let a = makeBook(title: "A")
        await presentUnloaded(h, a)
        h.engine.suspendLoads = true
        h.coordinator.togglePlayPause()
        await drain()
        h.coordinator.pause()
        h.engine.resumeSuspendedLoad()
        await drain()
        #expect(playCount(h.engine) == 0)
        #expect(h.coordinator.playbackPhase == .paused)
        #expect(h.coordinator.currentSession?.isPlaying == false)
    }

    @Test func pauseDuringSelectionLoadPreventsAutoplay() async {
        let h = makeHarness()
        let a = makeBook(title: "A")
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(a)
        await drain()
        h.coordinator.pause()
        h.engine.resumeSuspendedLoad()
        await drain()
        #expect(playCount(h.engine) == 0)
        #expect(h.coordinator.playbackPhase == .paused)
    }

    @Test func stopDuringLoadCannotRecreateSession() async {
        let h = makeHarness()
        let a = makeBook(title: "A")
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(a)
        await drain()
        h.coordinator.stopPlayback(forDeletedBook: a.book.id)
        h.engine.resumeSuspendedLoad()
        await drain()
        #expect(h.coordinator.currentSession == nil)
        #expect(h.coordinator.playbackPhase == .idle)
        #expect(playCount(h.engine) == 0)
    }

    @Test func legacyPlayIsInvalidatedByNewerSelection() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        h.engine.suspendLoads = true
        let legacy = Task { await h.coordinator.play(a) }
        await drain()
        h.coordinator.selectAndPlay(b)
        await drain()
        h.engine.resumeSuspendedLoad() // A
        await legacy.value
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // B
        await drain()
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(playCount(h.engine) == 1)
    }

    @Test func normalResumeStillPlays() async {
        let h = makeHarness()
        let a = makeBook(title: "A")
        await presentUnloaded(h, a)
        h.coordinator.togglePlayPause()
        await drain()
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(playCount(h.engine) == 1)
        #expect(h.engine.loadCalls.first?.startTime == 30)
    }
}
