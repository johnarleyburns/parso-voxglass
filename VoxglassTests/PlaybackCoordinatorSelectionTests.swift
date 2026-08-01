import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite(.serialized) struct PlaybackCoordinatorSelectionTests {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let store: MemoryPositionStore
        let snapshotStore: LastPlaybackSnapshotStore
        let bridge: NoopPlaybackBridge
    }

    private actor MemoryPositionStore: PositionStore {
        private struct Key: Hashable { let bookID: UUID; let chapterID: UUID }
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
            positions.values.filter { $0.bookID == bookID }.max { $0.updatedAt < $1.updatedAt }
        }
    }

    private func makeHarness() -> Harness {
        let engine = FakeAudioEngine()
        let store = MemoryPositionStore()
        let defaults = UserDefaults(suiteName: "sel-\(UUID().uuidString)")!
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        return Harness(coordinator: coordinator, engine: engine, store: store, snapshotStore: snapshotStore, bridge: bridge)
    }

    private func makeBook(title: String = "Test Book", chapters count: Int = 3) -> BookWithChapters {
        let bookID = UUID()
        let chapters = (0..<count).map { index in
            Chapter(
                bookID: bookID, title: "Chapter \(index)", index: index,
                duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        return BookWithChapters(book: Book(id: bookID, title: title, authors: ["A"], sourceID: UUID()), chapters: chapters)
    }

    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - S1 tests

    @Test func sessionAppearsBeforeEngineLoadCompletes() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()

        #expect(h.coordinator.currentSession != nil)  // Session must be visible before engine load completes
        #expect(h.coordinator.currentSession?.book.id == book.book.id)
        #expect(h.coordinator.playbackPhase == .preparing)  // Phase must be preparing while load is suspended

        h.engine.resumeAllSuspendedLoads()
        await drainMainQueue()

        #expect(h.coordinator.playbackPhase == .playing)  // Phase must be playing after load completes
    }

    @Test func phaseIsPreparingWhileEngineLoadIsSuspended() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()

        #expect(h.coordinator.playbackPhase == .preparing)
        #expect(!(h.engine.isPlaying))  // Engine must not be playing while load is suspended

        h.engine.resumeSuspendedLoad()
        await drainMainQueue()

        #expect(h.coordinator.playbackPhase == .playing)
        #expect(h.engine.isPlaying)
    }

    @Test func latestSelectionWinsWhenEarlierLoadFinishesLast() async {
        let h = makeHarness()
        let bookA = makeBook(title: "BookA")
        let bookB = makeBook(title: "BookB")
        h.engine.suspendLoads = true

        // Start loading BookA
        h.coordinator.selectAndPlay(bookA)
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookA.book.id)
        #expect(h.engine.loadCalls.count == 1)

        // Select BookB before BookA finishes — cancels BookA load
        h.coordinator.selectAndPlay(bookB)
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookB.book.id)  // Latest selection must win immediately
        #expect(h.coordinator.playbackPhase == .preparing)
        #expect(h.engine.loadCalls.count == 2)  // Must have issued load for BookB too

        // Finish the stale BookA load — it must not overwrite
        h.engine.resumeSuspendedLoad() // BookA completes first
        await drainMainQueue()
        // After BookA finishes but BookB is still the latest selection, session must still be BookB
        guard let sessionB = h.coordinator.currentSession else {
            Issue.record("Session must still exist"); return
        }
        #expect(sessionB.book.id == bookB.book.id)  // Stale BookA load must not overwrite BookB session
        #expect(h.coordinator.playbackPhase == .preparing)  // BookB is still preparing

        // Finish BookB load
        h.engine.resumeSuspendedLoad() // BookB completes
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookB.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func cancelledSelectionCannotPublishFailure() async {
        let h = makeHarness()
        let bookA = makeBook(title: "BookA")
        let bookB = makeBook(title: "BookB")
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(bookA)
        await drainMainQueue()
        #expect(h.coordinator.playbackError == nil)

        // Cancel BookA by selecting BookB
        h.coordinator.selectAndPlay(bookB)
        await drainMainQueue()

        // BookA was cancelled — fail its load
        h.engine.failSuspendedLoad(with: URLError(.cancelled))
        await drainMainQueue()

        // BookA's failure must not appear — the selection was cancelled
        #expect(h.coordinator.currentSession?.book.id == bookB.book.id)
        // If load failures have a message, it must be nil (not BookA's failure)
        if let err = h.coordinator.playbackError {
            #expect(!(err.contains("cancelled")))  // Cancelled selection error must not leak: \(err)
        }

        // Finish BookB successfully
        h.engine.resumeSuspendedLoad()
        await drainMainQueue()
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(h.coordinator.playbackError == nil)
    }

    @Test func repeatedPlayOfSamePreparingSelectionDoesNotStartSecondLoad() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()
        #expect(h.engine.loadCalls.count == 1)

        // Tap same book again while preparing — must be idempotent
        h.coordinator.selectAndPlay(book)
        await drainMainQueue()
        #expect(h.engine.loadCalls.count == 1)  // Duplicate tap on same preparing book must not start a second load

        h.engine.resumeSuspendedLoad()
        await drainMainQueue()
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func failedLoadKeepsSelectedSessionVisible() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.loadError = URLError(.notConnectedToInternet)

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()

        #expect(h.coordinator.currentSession != nil)  // Session must remain visible after load failure
        #expect(h.coordinator.currentSession?.book.id == book.book.id)
        #expect(h.coordinator.playbackError != nil)
        if case .failed = h.coordinator.playbackPhase {
            // expected
        } else {
            Issue.record("Phase must be .failed, got \(h.coordinator.playbackPhase)")
        }
    }

    @Test func retryUsesSelectedIdentity() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.loadError = URLError(.notConnectedToInternet)

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()

        #expect(h.engine.loadCalls.count == 1)
        #expect(h.coordinator.playbackError != nil)

        // Retry: clear error, select again
        h.engine.loadError = nil
        h.coordinator.selectAndPlay(book)
        await drainMainQueue()

        #expect(h.engine.loadCalls.count == 2)  // Retry must issue a new load
        #expect(h.coordinator.playbackPhase == .playing)
        #expect(h.coordinator.playbackError == nil)
    }

    @Test func clearingPlaybackCancelsSelectionAndProgressTasks() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(book)
        await drainMainQueue()
        #expect(h.coordinator.playbackPhase == .preparing)

        // Clear playback by deleting book (stopPlayback)
        h.coordinator.stopPlayback(forDeletedBook: book.book.id)
        await drainMainQueue()

        #expect(h.coordinator.currentSession == nil)
        #expect(h.coordinator.playbackPhase == .idle)

        // Resume the suspended load — it must not resurrect the session
        h.engine.resumeAllSuspendedLoads()
        await drainMainQueue()
        #expect(h.coordinator.currentSession == nil)  // Cleared session must not be resurrected by stale load
    }

    @Test func selectAndPlayDifferentBookSupersedesPreparingRequest() async {
        let h = makeHarness()
        let bookA = makeBook(title: "BookA")
        let bookB = makeBook(title: "BookB")
        h.engine.suspendLoads = true

        h.coordinator.selectAndPlay(bookA)
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookA.book.id)

        // Supersede with BookB — BookB must appear immediately, even before engine loads
        h.coordinator.selectAndPlay(bookB)
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookB.book.id)
        #expect(h.coordinator.playbackPhase == .preparing)

        h.engine.resumeAllSuspendedLoads()
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.book.id == bookB.book.id)
        #expect(h.coordinator.playbackPhase == .playing)
    }

    @Test func playbackErrorIsClearedOnNewSelection() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.loadError = URLError(.notConnectedToInternet)

        await h.coordinator.play(book)
        #expect(h.coordinator.playbackError != nil)

        h.engine.loadError = nil
        await h.coordinator.play(makeBook(title: "BookB"))
        #expect(h.coordinator.playbackError == nil)  // Error must be cleared on new selection
    }

    @Test func playPublishesPreparingBeforeEngineLoad() async {
        let h = makeHarness()
        let book = makeBook()
        h.engine.suspendLoads = true

        // Start play but don't let load finish
        let playTask = Task {
            await h.coordinator.play(book)
        }
        await drainMainQueue()

        #expect(h.coordinator.currentSession != nil)  // Session must be visible before engine load
        #expect(h.coordinator.playbackPhase == .preparing)

        h.engine.resumeAllSuspendedLoads()
        await playTask.value
        await drainMainQueue()

        #expect(h.coordinator.playbackPhase == .playing)
        #expect(h.coordinator.currentSession != nil)
    }
}
