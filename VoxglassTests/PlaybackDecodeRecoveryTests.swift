import Foundation
import Testing
@testable import VoxglassCore

@MainActor
@Suite struct PlaybackDecodeRecoveryTests {
    private struct Harness {
        let engine: FakeAudioEngine
        let coordinator: PlaybackCoordinator
        let book: BookWithChapters
        let snapshot: LastPlaybackSnapshotStore
        let positions: SQLitePositionStore
    }

    private func makeHarness(offset: TimeInterval = 0) async -> Harness {
        let id = UUID()
        let book = Book(id: id, title: "The Possessed", authors: ["Fyodor Dostoyevsky"], sourceID: UUID())
        let chapter = Chapter(bookID: id, title: "57 - The Fête", index: 56,
                              startTime: offset, duration: 1232,
                              localURL: URL(fileURLWithPath: "/tmp/possessed-57.mp3"))
        let engine = FakeAudioEngine()
        let db = AppDatabase.makeTemporaryDatabase(named: "decode-\(id)")
        try? await db.execute(
            "INSERT INTO sources (id, kind, title, created_at) VALUES (?, ?, ?, ?)",
            [.string(book.sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("Local"), .double(0)]
        )
        try? await db.execute(
            "INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.string(id.uuidString), .string(book.title), .string("[]"), .string(book.sourceID.uuidString), .double(0), .double(0), .bool(false)]
        )
        try? await db.execute(
            "INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds) VALUES (?, ?, ?, ?, ?, ?)",
            [.string(chapter.id.uuidString), .string(id.uuidString), .string(chapter.title), .string(chapter.sortKey), .int(56), .double(1232)]
        )
        let positions = SQLitePositionStore(database: db)
        let defaults = UserDefaults(suiteName: "decode-\(id)")!
        let snapshot = LastPlaybackSnapshotStore(defaults: defaults)
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: positions, snapshotStore: snapshot)
        let bwc = BookWithChapters(book: book, chapters: [chapter])
        await coordinator.play(bwc)
        engine.currentTime = offset + 172
        await coordinator.tickProgress()
        return Harness(engine: engine, coordinator: coordinator, book: bwc, snapshot: snapshot, positions: positions)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }

    @Test func skipsExactlyThreeSecondsBeforeAlerting() async {
        let h = await makeHarness()
        for attempt in 1...3 {
            h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
            #expect(h.coordinator.decodeRecoveryAttempt == attempt)
            #expect(h.coordinator.playbackError == nil)
            await waitUntil { h.engine.loadCalls.count == attempt + 1 && h.coordinator.playbackPhase == .playing }
            #expect(h.engine.loadCalls.last?.startTime == Double(172 + attempt))
            #expect(h.snapshot.position(forBookID: h.book.book.id)?.position == Double(172 + attempt))
        }
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        #expect(h.engine.loadCalls.count == 4)
        #expect(h.coordinator.playbackError == "Cannot Decode")
        #expect(!h.engine.isPlaying)
        #expect(h.coordinator.currentSession?.chapter.id == h.book.chapters[0].id)
        #expect(h.coordinator.currentSession?.position == 175)
        h.coordinator.pause()
    }

    @Test func reloadFailuresConsumeSameThreeAttemptBudget() async {
        let h = await makeHarness()
        h.engine.loadError = NSError(domain: "AVFoundationErrorDomain", code: -11821,
                                     userInfo: [NSLocalizedDescriptionKey: "Cannot Decode"])
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.coordinator.playbackError != nil }
        #expect(h.engine.loadCalls.map(\.startTime) == [0, 173, 174, 175])
        #expect(h.coordinator.decodeRecoveryAttempt == nil)
        #expect(h.snapshot.position(forBookID: h.book.book.id)?.position == 175)
    }

    @Test func pauseCancelsPendingRecovery() async {
        let h = await makeHarness()
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        h.coordinator.pause()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.engine.loadCalls.count == 1)
        #expect(!h.engine.isPlaying)
        #expect(h.coordinator.decodeRecoveryAttempt == nil)
        #expect(h.coordinator.playbackPhase == .paused)
    }

    @Test func seekCancelsPendingRecoveryAndKeepsUserPosition() async {
        let h = await makeHarness()
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await h.coordinator.seek(to: 200)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.engine.loadCalls.count == 1)
        #expect(h.coordinator.currentSession?.position == 200)
        #expect(h.snapshot.position(forBookID: h.book.book.id)?.position == 200)
    }

    @Test func sharedAssetAddsChapterOffset() async {
        let h = await makeHarness(offset: 1000)
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.engine.loadCalls.count == 2 && h.engine.isPlaying }
        #expect(h.engine.loadCalls.last?.startTime == 1173)
        #expect(h.coordinator.currentSession?.position == 173)
        h.coordinator.pause()
    }

    @Test func healthyPlaybackResetsBudget() async {
        let h = await makeHarness()
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.engine.loadCalls.count == 2 && h.engine.isPlaying }
        h.engine.currentTime = 176
        await h.coordinator.tickProgress()
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        #expect(h.coordinator.decodeRecoveryAttempt == 1)
        h.coordinator.pause()
    }

    @Test func unrelatedFailureDoesNotSkipAudio() async {
        let h = await makeHarness()
        h.engine.firePlaybackIssue(.failed("Network unavailable"))
        #expect(h.engine.loadCalls.count == 1)
        #expect(h.coordinator.playbackError == "Network unavailable")
        #expect(h.coordinator.currentSession?.position == 172)
    }

    @Test func notificationDuringReloadDoesNotResumeFailedItem() async {
        let h = await makeHarness()
        h.engine.suspendLoads = true
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        h.engine.resumeSuspendedLoad()
        await waitUntil { h.engine.loadCalls.count == 3 }
        #expect(h.coordinator.decodeRecoveryAttempt == 2)
        #expect(!h.engine.isPlaying)
        h.coordinator.pause()
        h.engine.resumeSuspendedLoad()
    }

    @Test func pauseDuringSuspendedReloadNeverRestartsPlayback() async {
        let h = await makeHarness()
        h.engine.suspendLoads = true
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.engine.loadCalls.count == 2 }
        h.coordinator.pause()
        h.engine.resumeSuspendedLoad()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!h.engine.isPlaying)
        #expect(h.coordinator.playbackPhase == .paused)
    }

    @Test func explicitRetrySupersedesPreparingRecovery() async {
        let h = await makeHarness()
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        h.coordinator.retryPlayback()
        await waitUntil { h.engine.loadCalls.count == 2 && h.engine.isPlaying }
        #expect(h.coordinator.decodeRecoveryAttempt == nil)
        #expect(h.engine.loadCalls.last?.startTime == 173)
        h.coordinator.pause()
    }

    @Test func decodeFailureDuringLazyLoadAlsoRecovers() async {
        let h = await makeHarness()
        await h.coordinator.present(h.book)
        h.engine.loadError = NSError(domain: "AVFoundationErrorDomain", code: -11821,
                                     userInfo: [NSLocalizedDescriptionKey: "Cannot Decode"])
        h.coordinator.togglePlayPause()
        await waitUntil { h.engine.loadCalls.count == 5 && h.coordinator.playbackError != nil }
        #expect(h.engine.loadCalls.map(\.startTime) == [0, 172, 173, 174, 175])
        #expect(h.coordinator.currentSession?.position == 175)
    }

    @Test func playButtonAfterExhaustionStartsFreshRecoveryBudget() async {
        let h = await makeHarness()
        h.engine.loadError = NSError(domain: "AVFoundationErrorDomain", code: -11821,
                                     userInfo: [NSLocalizedDescriptionKey: "Cannot Decode"])
        h.engine.firePlaybackIssue(.decodeFailed("Cannot Decode"))
        await waitUntil { h.engine.loadCalls.count == 4 && h.coordinator.playbackError != nil }
        h.coordinator.togglePlayPause()
        await waitUntil { h.engine.loadCalls.count == 8 && h.coordinator.playbackError != nil }
        #expect(h.engine.loadCalls.last?.startTime == 178)
    }

    @Test func decodeClassifierUsesCodesIncludingWrappedLocalizedErrors() {
        let decode = NSError(domain: "AVFoundationErrorDomain", code: -11821,
                             userInfo: [NSLocalizedDescriptionKey: "Localized decoder failure"])
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: decode])
        #expect(AudioEngineIssue.playbackFailure(decode, fallback: "fallback") == .decodeFailed("Localized decoder failure"))
        if case .decodeFailed = AudioEngineIssue.playbackFailure(wrapped, fallback: "fallback") {} else {
            Issue.record("Wrapped decoder error was not classified")
        }
        #expect(AudioEngineIssue.playbackFailure(URLError(.timedOut), fallback: "fallback") == .failed(URLError(.timedOut).localizedDescription))
    }
}
