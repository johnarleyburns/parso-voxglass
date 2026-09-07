import Testing
import Foundation
import ParsoAudioStreaming
import VoxglassCoreTestSupport
@testable import VoxglassCore

/// A single-file, multi-chapter local import (Phase 9's local-folder import,
/// where every chapter shares one on-disk audio file and is distinguished
/// only by `startTime`/`duration`) exposed two real regressions that never
/// showed up with this suite's other fixtures, where every chapter has its
/// own separate file starting at zero:
///
/// 1. Two of the four `engine.load(url:startTime:)` call sites forgot to add
///    `chapter.startTime` to the resume-relative offset, so tapping any
///    chapter but the first (or resuming a background session) always
///    seeked to the very start of the shared file instead of that chapter's
///    real position.
/// 2. A chapter's own known-correct `duration` could be silently overridden
///    by a stale, mismatched `savedDuration` from a previous session,
///    corrupting the "remaining time" display and self-perpetuating via the
///    resume snapshot on every subsequent load.
@MainActor
@Suite(.serialized) struct SharedAssetChapterNavigationTests {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let store: MemoryPositionStore
        let snapshotStore: LastPlaybackSnapshotStore
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
        let cacheStore = SparseCacheStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-asset-cache-\(UUID().uuidString)", isDirectory: true)
        )
        let defaults = UserDefaults(suiteName: "shared-asset-\(UUID().uuidString)")!
        let snapshotStore = LastPlaybackSnapshotStore(defaults: defaults)
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: snapshotStore,
            rateStore: PlaybackRateStore(defaults: defaults),
            cacheStore: cacheStore,
            bridge: NoopPlaybackBridge()
        )
        return Harness(coordinator: coordinator, engine: engine, store: store, snapshotStore: snapshotStore)
    }

    /// Mirrors a real local-folder import: every chapter points at the same
    /// `localURL`, distinguished only by `startTime`/`duration` — exactly
    /// `LocalAudiobookPreparer`'s output shape.
    private func makeSharedAssetBook() -> BookWithChapters {
        let bookID = UUID()
        let sharedURL = URL(fileURLWithPath: "/tmp/\(bookID.uuidString)/book.m4a")
        let chapters = [
            Chapter(bookID: bookID, title: "The Texan", index: 0, startTime: 170, duration: 1251, localURL: sharedURL),
            Chapter(bookID: bookID, title: "Yossarian", index: 1, startTime: 1421, duration: 1687, localURL: sharedURL),
            Chapter(bookID: bookID, title: "Hungry Joe", index: 2, startTime: 3108, duration: 900, localURL: sharedURL)
        ]
        return BookWithChapters(
            book: Book(id: bookID, title: "Shared Asset Book", authors: ["Author"], sourceID: UUID()),
            chapters: chapters
        )
    }

    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func directChapterTapSeeksToTheChaptersOwnAbsolutePosition() async {
        let h = makeHarness()
        let book = makeSharedAssetBook()

        // Tap chapter 3 directly (e.g. from ChaptersView) — not chapter 1,
        // and not a chapter with a saved position.
        await h.coordinator.play(book, chapter: book.chapters[2])

        #expect(h.engine.loadCalls.count == 1)
        #expect(h.engine.loadCalls.first?.url == book.chapters[2].localURL)
        // Regression: this used to load at startTime: 0 (the file's own
        // start) instead of the chapter's real absolute offset (3108).
        #expect(abs((h.engine.loadCalls.first?.startTime ?? -1) - 3108) <= 0.001)
    }

    @Test func resumingAPresentedSessionSeeksToTheChaptersAbsolutePositionPlusSavedOffset() async throws {
        let h = makeHarness()
        let book = makeSharedAssetBook()
        try await h.store.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: book.chapters[1].id,
            position: 42, // 42s into "Yossarian", not the book
            duration: 1687
        ))

        await h.coordinator.present(book)
        h.engine.reset()
        h.coordinator.togglePlayPause()
        var waited: UInt64 = 0
        while h.engine.loadCalls.isEmpty && waited < 5_000_000_000 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 20_000_000
        }

        #expect(h.engine.loadCalls.count == 1)
        // Regression: this used to load at startTime: 42 (chapter-relative)
        // instead of chapter.startTime (1421) + 42 = 1463.
        #expect(abs((h.engine.loadCalls.first?.startTime ?? -1) - 1463) <= 0.001)
    }

    @Test func sessionDurationAlwaysUsesTheChaptersOwnKnownDuration() async throws {
        let h = makeHarness()
        let book = makeSharedAssetBook()

        // A stale snapshot for chapter 1 ("The Texan", duration 1251)
        // carrying a *different* chapter's duration value — the exact shape
        // of the corruption found live: a snapshot whose (book, chapter) ID
        // pair is correct but whose duration field is wrong.
        h.snapshotStore.save(PlaybackPosition(
            bookID: book.book.id,
            chapterID: book.chapters[0].id,
            position: 0,
            duration: 1687, // "Yossarian"'s duration, not chapter 1's
            updatedAt: Date()
        ))

        await h.coordinator.play(book, chapter: book.chapters[0])

        // The chapter's own duration must win over the stale saved value.
        #expect(h.coordinator.currentSession?.duration == 1251)
        #expect(h.coordinator.playheadDuration == 1251)
    }
}
