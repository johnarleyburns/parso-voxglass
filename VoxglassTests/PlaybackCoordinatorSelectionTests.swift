import Testing
import Foundation
@testable import VoxglassWatchProtocol
@testable import VoxglassWatchCore
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
        func positions(forBookID bookID: UUID) async throws -> [PlaybackPosition] {
            positions.values.filter { $0.bookID == bookID }
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

    @Test func pairedCheckpointPersistsAndUpdatesAPausedMatchingSession() async {
        let h = makeHarness()
        let book = makeBook(chapters: 1)
        await h.coordinator.present(book)
        let chapter = book.chapters[0]
        let checkpoint = PlaybackPosition(bookID: book.book.id, chapterID: chapter.id,
                                          position: 42, duration: 100, updatedAt: Date())
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(checkpoint))
        let saved = try? await h.store.position(for: book.book.id, chapterID: chapter.id)
        #expect(saved?.position == 42)
        #expect(h.coordinator.currentSession?.position == 42)
        #expect(h.coordinator.playhead == 42)
    }

    @Test func pairedCheckpointNewerThanPhoneWinsAndOlderLoses() async {
        let h = makeHarness()
        let book = makeBook(chapters: 1)
        await h.coordinator.present(book)
        let chapter = book.chapters[0]
        let now = Date()
        func cp(_ pos: TimeInterval, _ age: TimeInterval) -> PlaybackPosition {
            PlaybackPosition(bookID: book.book.id, chapterID: chapter.id, position: pos,
                             duration: 100, updatedAt: now.addingTimeInterval(age))
        }
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(cp(10, 0)))
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(cp(60, 10)))
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(cp(20, 5))))
        let saved = try? await h.store.position(for: book.book.id, chapterID: chapter.id)
        #expect(saved?.position == 60)
    }

    @Test func pairedCheckpointCannotOverrideActivePhonePlayback() async {
        let h = makeHarness()
        let book = makeBook(chapters: 1)
        h.coordinator.selectAndPlay(book)
        await waitUntil { h.coordinator.currentSession?.isPlaying == true }
        let chapter = book.chapters[0]
        let checkpoint = PlaybackPosition(bookID: book.book.id, chapterID: chapter.id,
                                          position: 42, duration: 100, updatedAt: Date())
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(checkpoint)))
        let saved = try? await h.store.position(for: book.book.id, chapterID: chapter.id)
        #expect(saved == nil)
    }

    private func watchPoint(_ book: BookWithChapters, _ chapter: Int, _ pos: TimeInterval, _ at: TimeInterval) -> PlaybackPosition {
        PlaybackPosition(bookID: book.book.id, chapterID: book.chapters[chapter].id, position: pos,
                         duration: 100, updatedAt: Date(timeIntervalSince1970: at))
    }

    private func furthestSaved(_ h: Harness, _ book: BookWithChapters) async -> PlaybackPosition? {
        var best: PlaybackPosition?
        for c in book.chapters {
            if let p = try? await h.store.position(for: book.book.id, chapterID: c.id) { best = p }
        }
        return best
    }

    @Test func watchCheckpointAtBeginningCannotReplaceFartherPhoneChapter() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 2, 42, 100))
        await h.coordinator.present(book)
        let accepted = await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 0, 0, 999))
        #expect(!accepted)
        let saved = try await h.store.position(for: book.book.id, chapterID: book.chapters[0].id)
        #expect(saved == nil)
        #expect(await furthestSaved(h, book)?.position == 42)
    }

    @Test func fartherWatchChapterIsAcceptedEvenWhenItsTimestampIsOlder() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 1, 80, 999))
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 2, 4, 100), chapters: book.chapters))
    }

    @Test func sameChapterBehindIsRejectedAndAheadAccepted() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 1, 50, 100))
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 1, 10, 999), chapters: book.chapters)))
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 1, 60, 50), chapters: book.chapters))
        #expect(await furthestSaved(h, book)?.position == 60)
    }

    @Test func samePointWithNewerTimestampPersists() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 1, 50, 100))
        #expect(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 1, 50, 200), chapters: book.chapters))
    }

    @Test func unknownChapterFailsClosed() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 1, 50, 100))
        let stray = PlaybackPosition(bookID: book.book.id, chapterID: UUID(), position: 5, duration: 100,
                                     updatedAt: Date(timeIntervalSince1970: 999))
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(stray, chapters: book.chapters)))
        #expect(await furthestSaved(h, book)?.position == 50)
    }

    @Test func rejectedCheckpointLeavesPausedSessionUnchanged() async throws {
        let h = makeHarness()
        let book = makeBook()
        try await h.store.save(watchPoint(book, 0, 30, 100))
        await h.coordinator.present(book)
        let before = h.coordinator.playhead
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 0, 0, 999))))
        #expect(h.coordinator.playhead == before)
    }

    @Test func activePhoneRejectsFartherWatchCheckpoint() async {
        let h = makeHarness()
        let book = makeBook()
        h.coordinator.selectAndPlay(book)
        await waitUntil { h.coordinator.currentSession?.isPlaying == true }
        #expect(!(await h.coordinator.persistExternalPlaybackCheckpoint(watchPoint(book, 2, 5, 999), chapters: book.chapters)))
    }

    /// Polls (yielding to the main actor) so contended parallel runs cannot
    /// outlast a fixed sleep.
    private func waitUntil(_ condition: () -> Bool, timeoutNanoseconds: UInt64 = 10_000_000_000) async {
        var waited: UInt64 = 0
        while waited < timeoutNanoseconds, !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 20_000_000
        }
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
        await waitUntil { h.engine.loadCalls.count == 1 }

        #expect(h.coordinator.playbackPhase == .preparing)
        #expect(!(h.engine.isPlaying))  // Engine must not be playing while load is suspended

        h.engine.resumeSuspendedLoad()
        await waitUntil { h.coordinator.playbackPhase == .playing }

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

    // MARK: - Furthest saved point (Watch catalog projection)

    private func catalogMarkers(_ h: Harness, _ book: BookWithChapters) async -> [Double?] {
        let saved = await h.coordinator.effectiveFurthestSavedPosition(for: book)
        let dto = WatchBookDTO(id: .init(book.book.id.uuidString), title: "B", chapters: book.chapters.map {
            WatchChapterDTO(id: .init($0.id.uuidString), index: $0.index, title: $0.title, duration: 100, resumePosition: 9)
        })
        let snapshot = PhoneWatchProjection.applyingResolvedResume(
            book: book, saved: saved,
            to: WatchLibrarySnapshot(pairedLibraryID: "library", revision: 1, books: [dto]))
        return snapshot.books[0].chapters.map(\.resumePosition)
    }

    @Test func catalogMarksFartherPhoneChapterEvenWhenBeginningRowIsNewer() async throws {
        let h = makeHarness()
        let book = makeBook(chapters: 4)
        try await h.store.save(watchPoint(book, 0, 0, 999))
        try await h.store.save(watchPoint(book, 3, 42, 100))
        #expect(await catalogMarkers(h, book) == [nil, nil, nil, 42])
    }

    @Test func fartherInMemorySnapshotBeatsEarlierDurableRow() async throws {
        let h = makeHarness()
        let book = makeBook(chapters: 4)
        try await h.store.save(watchPoint(book, 1, 10, 100))
        h.snapshotStore.save(watchPoint(book, 2, 30, 50))
        #expect(await catalogMarkers(h, book) == [nil, nil, 30, nil])
    }

    @Test func laterChapterAtZeroBeatsNonzeroEarlierChapter() async throws {
        let h = makeHarness()
        let book = makeBook(chapters: 4)
        try await h.store.save(watchPoint(book, 1, 50, 999))
        try await h.store.save(watchPoint(book, 2, 0, 1))
        #expect(await catalogMarkers(h, book) == [nil, nil, 0, nil])
    }

    @Test func finishedChaptersAndMissingPositionResolveAsBefore() async throws {
        let h = makeHarness()
        let book = makeBook(chapters: 3)
        #expect(await catalogMarkers(h, book) == [0, nil, nil])
        var done = watchPoint(book, 1, 100, 10)
        done.isFinished = true
        try await h.store.save(done)
        #expect(await catalogMarkers(h, book) == [nil, nil, 0])
        var last = watchPoint(book, 2, 100, 11)
        last.isFinished = true
        try await h.store.save(last)
        #expect(await catalogMarkers(h, book) == [0, nil, nil])
    }

    @Test func booksResolveIndependently() async throws {
        let h = makeHarness()
        let a = makeBook(chapters: 3)
        let b = makeBook(chapters: 3)
        try await h.store.save(watchPoint(a, 2, 5, 1))
        #expect(await catalogMarkers(h, a) == [nil, nil, 5])
        #expect(await catalogMarkers(h, b) == [0, nil, nil])
    }
}
