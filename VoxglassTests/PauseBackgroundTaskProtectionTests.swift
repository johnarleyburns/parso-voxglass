import Testing
import Foundation
@testable import VoxglassCore

/// A paused/interrupted/route-changed position must be flushed inside a
/// platform background-task assertion, not a bare `Task`, so an OS suspend
/// immediately after pausing can't drop the write. `NoopPlaybackBridge` is
/// `final`, so this is a small standalone spy.
@MainActor
private final class RecordingBridge: PlaybackPlatformBridge {
    var onRemoteCommand: ((PlaybackRemoteCommand) -> Void)?
    private(set) var backgroundTaskInvocations = 0

    func updateNowPlaying(_ info: NowPlayingInfo?) {}
    func updateLockScreen(nowPlaying: NowPlayingInfo?) {}
    func updateAuxiliaryNowPlaying(title: String, artist: String) {}
    func clearAuxiliaryNowPlaying() {}
    func setArtwork(_ imageData: Data?) {}
    func setSkipIntervals(backward: Int, forward: Int) {}

    func runWithBackgroundTask(_ work: @escaping @MainActor () async -> Void) {
        backgroundTaskInvocations += 1
        Task { @MainActor in await work() }
    }
}

@MainActor
@Suite struct PauseBackgroundTaskProtectionTests {

    private func makeChapters(_ count: Int, bookID: UUID) -> [Chapter] {
        (0..<count).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: 300,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
    }

    private func seedBook(in db: AppDatabase, chapters: [Chapter]) async throws {
        let bookID = chapters.first!.bookID
        let sourceID = UUID()
        let now = Date().timeIntervalSince1970
        try await db.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        for chapter in chapters {
            try await db.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .string(chapter.id.uuidString), .string(bookID.uuidString), .string(chapter.title),
                .string(chapter.sortKey), .int(Int64(chapter.index)),
                chapter.duration.map { .double($0) } ?? .null, .null,
                chapter.localURL.map { .string($0.absoluteString) } ?? .null
            ])
        }
    }

    @Test func pauseFlushesPositionThroughBackgroundTaskAssertion() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "pause-bg-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLitePositionStore(database: db)
        let defaults = UserDefaults(suiteName: "pause-bg-\(UUID().uuidString)")!
        let bridge = RecordingBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        let bookID = UUID()
        let chapters = makeChapters(1, bookID: bookID)
        try await seedBook(in: db, chapters: chapters)
        let book = BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chapters)

        await coordinator.play(book)
        engine.currentTime = 42
        coordinator.pause()

        // Let the background-task-wrapped persist Task run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(bridge.backgroundTaskInvocations >= 1)  // pause() must flush through runWithBackgroundTask, not a bare Task
        let saved = try await store.position(for: bookID, chapterID: chapters[0].id)
        #expect(abs((saved?.position ?? -1) - 42) <= 0.001)
    }

    @Test func audioRouteChangeFlushesPositionThroughBackgroundTaskAssertion() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "route-bg-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLitePositionStore(database: db)
        let defaults = UserDefaults(suiteName: "route-bg-\(UUID().uuidString)")!
        let bridge = RecordingBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        let bookID = UUID()
        let chapters = makeChapters(1, bookID: bookID)
        try await seedBook(in: db, chapters: chapters)
        let book = BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chapters)

        await coordinator.play(book)
        engine.currentTime = 17
        coordinator.handleAudioRouteChanged()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(bridge.backgroundTaskInvocations >= 1)  // A CarPlay connect/disconnect route change must flush through runWithBackgroundTask too
    }
}
