import Testing
import Foundation
@testable import VoxglassCore

/// Consumer-playback regression suite: AVFoundation can report a premature
/// end-of-playback on some device/file combinations (e.g. a 20-minute chapter
/// "ending" at 5:00), which would otherwise skip to the next track. The engine
/// reports the ended item's position/duration (`lastEndPosition`/
/// `lastEndDuration`) and the coordinator must reject a spurious item change.
@MainActor
@Suite struct PlaybackSpuriousEndTests {

    private func makeBook(chapters: Int = 2) -> BookWithChapters {
        let bookID = UUID()
        let chs = (0..<chapters).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        let book = Book(id: bookID, title: "Possessed", authors: ["A"], sourceID: UUID())
        return BookWithChapters(book: book, chapters: chs)
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine) {
        let db = AppDatabase.makeTemporaryDatabase(named: "spurious-end-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: SQLitePositionStore(database: db)
        )
        return (coordinator, engine)
    }

    /// Polls the MainActor call log until `predicate` holds or the budget expires,
    /// letting the fire-and-forget `handleItemChanged` Task complete.
    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func spuriousItemChangeRevertsToCurrentChapter() async {
        let (coordinator, engine) = makeCoordinator()
        let book = makeBook()
        await coordinator.play(book)

        let firstChapter = book.chapters[0]
        #expect(coordinator.currentSession?.chapter.id == firstChapter.id)

        // The engine saw an end at 60s of a 100s chapter — nowhere near the
        // real end. The queue advanced anyway (AVQueuePlayer glitch): the
        // coordinator must revert to the chapter the user was listening to.
        engine.currentTime = 60
        engine.duration = 100
        engine.isPlaying = true
        engine.lastEndPosition = 60
        engine.lastEndDuration = 100

        engine.fireItemChanged()
        await waitUntil {
            engine.loadCalls.last?.startTime == 60
        }

        #expect(coordinator.currentSession?.chapter.id == firstChapter.id)
        #expect(engine.loadCalls.last?.url == firstChapter.localURL)
        #expect(engine.loadCalls.last?.startTime == 60)
    }

    @Test func genuineItemChangeAdvancesToNextChapter() async {
        let (coordinator, engine) = makeCoordinator()
        let book = makeBook()
        await coordinator.play(book)

        // A real end: position == duration.
        engine.currentTime = 100
        engine.duration = 100
        engine.isPlaying = true
        engine.lastEndPosition = 100
        engine.lastEndDuration = 100

        engine.fireItemChanged()
        await waitUntil {
            coordinator.currentSession?.chapter.id == book.chapters[1].id
        }

        #expect(coordinator.currentSession?.chapter.id == book.chapters[1].id)
    }

    @Test func unverifiedEndStillAdvances() async {
        let (coordinator, engine) = makeCoordinator()
        let book = makeBook()
        await coordinator.play(book)

        // Unknown duration (e.g. streaming): `lastEndDuration` is nil, so the
        // coordinator must not reject the change.
        engine.currentTime = 0
        engine.duration = nil
        engine.isPlaying = true
        engine.lastEndPosition = 0
        engine.lastEndDuration = nil

        engine.fireItemChanged()
        await waitUntil {
            coordinator.currentSession?.chapter.id == book.chapters[1].id
        }

        #expect(coordinator.currentSession?.chapter.id == book.chapters[1].id)
    }
}
