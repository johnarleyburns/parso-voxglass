import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite struct PlaybackCoordinatorOwnershipTests {

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
        let defaults = InMemoryDefaultsStore()
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: EmptyPositionStore(),
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: NoopPlaybackBridge(),
            defaults: defaults
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
        // Wait for A to actually reach the suspended engine load; a fixed
        // sleep can let B overtake it on a contended runner, which would make
        // the first resumed load B instead of the stale A.
        await waitUntil { h.engine.loadCalls.count == 1 }
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.resumeSuspendedLoad() // A (stale)
        await drain()
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // B
        await waitUntil { h.coordinator.playbackPhase == .playing }
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
        // Wait for A's lazy load to reach the suspended engine load before
        // selecting B; otherwise B can become the first pending load and the
        // resume below would legitimately start B early.
        await waitUntil { h.engine.loadCalls.count == 1 }
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.resumeSuspendedLoad() // A's lazy load
        await drain()
        #expect(playCount(h.engine) == 0)
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .preparing)
        h.engine.resumeSuspendedLoad() // B
        await waitUntil { h.coordinator.playbackPhase == .playing }
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(playCount(h.engine) == 1)
    }

    @Test func rapidSelectionLeavesLastSelectionAsOnlyOwner() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B"), c = makeBook(title: "C")
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(a)
        await waitUntil { h.engine.loadCalls.count == 1 }
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.coordinator.selectAndPlay(c)
        await waitUntil { h.engine.loadCalls.count == 3 }
        h.engine.resumeSuspendedLoad() // A
        h.engine.resumeSuspendedLoad() // B
        await drain()
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // C
        await waitUntil { h.coordinator.playbackPhase == .playing }
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
        await waitUntil { h.engine.loadCalls.count == 1 }
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
        await waitUntil { h.engine.loadCalls.count == 1 }
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
        await waitUntil { h.engine.loadCalls.count == 1 }
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
        await waitUntil { h.engine.loadCalls.count == 1 }
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.resumeSuspendedLoad() // A
        await legacy.value
        #expect(playCount(h.engine) == 0)
        h.engine.resumeSuspendedLoad() // B
        await waitUntil { h.coordinator.playbackPhase == .playing }
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

    @Test func staleProgressTickCannotStompNewerSelection() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        h.coordinator.selectAndPlay(a)
        await drain()
        #expect(h.coordinator.playbackPhase == .playing)
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        // Engine reads not-playing mid-load; a stale loop tick must be inert.
        h.engine.isPlaying = false
        await h.coordinator.tickProgress(generation: 0)
        #expect(h.coordinator.playbackPhase == .preparing)
        h.engine.resumeSuspendedLoad()
        await waitUntil { h.coordinator.playbackPhase == .playing }
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func reportedSequenceSettlesPlayingForRevisitedBook() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        h.coordinator.selectAndPlay(a)
        await drain()
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.isPlaying = false
        await h.coordinator.tickProgress(generation: 0)
        h.coordinator.selectAndPlay(a)
        await waitUntil { h.engine.loadCalls.count == 3 }
        h.engine.resumeSuspendedLoad() // B (superseded)
        h.engine.resumeSuspendedLoad() // A
        await waitUntil { h.coordinator.playbackPhase == .playing }
        #expect(h.coordinator.currentSession?.book.id == a.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func staleEngineIssueCannotMutateNewerSession() async {
        let h = makeHarness()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        h.coordinator.selectAndPlay(a)
        await drain()
        h.engine.suspendLoads = true
        h.coordinator.selectAndPlay(b)
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.onPlaybackIssue?(.failed("stale item failure"))
        #expect(h.coordinator.playbackPhase == .preparing)
        #expect(h.coordinator.currentSession?.book.id == b.book.id)
        h.engine.resumeSuspendedLoad()
        await waitUntil { h.coordinator.playbackPhase == .playing }
        #expect(h.coordinator.playbackPhase == .playing)
    }
}
