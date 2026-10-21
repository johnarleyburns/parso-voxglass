import Testing
import Foundation
@testable import VoxglassCore

/// Lock-screen artwork caching (P0-4): fetched once per book, never per tick, and
/// a fallback covers books with no art. Asserted against a counting fake provider
/// (returning raw `Data`) and a `NoopPlaybackBridge`, so no network / MediaPlayer.
@MainActor
@Suite struct NowPlayingArtworkTests {

    /// MainActor call counter (both the test and the provider run on MainActor).
    private final class FetchCounter { var count = 0 }
    /// Stand-in cover bytes; the coordinator only forwards them to the bridge.
    private let coverData = Data([0x01, 0x02, 0x03])

    private func makeBook(title: String, cover: Bool) -> BookWithChapters {
        let bookID = UUID()
        let chapter = Chapter(
            bookID: bookID, title: "Ch 0", index: 0, duration: 100,
            localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString).mp3")
        )
        let book = Book(
            title: title, authors: ["A"], sourceID: UUID(),
            coverURL: cover ? URL(string: "https://archive.org/services/img/\(bookID.uuidString)") : nil
        )
        return BookWithChapters(book: book, chapters: [chapter])
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func artworkFetchedOncePerBookNotPerTick() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-once-\(UUID().uuidString)")
        let coordinator = PlaybackCoordinator(engine: FakeAudioEngine(), positionStore: SQLitePositionStore(database: db))
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "A", cover: true))
        await waitUntil { counter.count >= 1 }

        // Simulate 10 "ticks" — each re-emits Now Playing but must not re-fetch.
        for _ in 0..<10 { coordinator.setPlaybackRate(1.0) }

        #expect(counter.count == 1)  // Cover art is fetched once per book, not per tick
    }

    @Test func fallbackUsedWhenCoverURLIsNil() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-fallback-\(UUID().uuidString)")
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: FakeAudioEngine(),
            positionStore: SQLitePositionStore(database: db),
            bridge: bridge
        )
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "No Cover", cover: false))

        #expect(bridge.lastArtworkData == .some(nil))  // A coverless book still requests fallback artwork (setArtwork(nil))
        #expect(counter.count == 0)  // No fetch is attempted when there is no cover URL
    }

    @Test func artworkRefreshesOnBookChange() async {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-change-\(UUID().uuidString)")
        let coordinator = PlaybackCoordinator(engine: FakeAudioEngine(), positionStore: SQLitePositionStore(database: db))
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return self.coverData }

        await coordinator.play(makeBook(title: "A", cover: true))
        await waitUntil { counter.count >= 1 }
        await coordinator.play(makeBook(title: "B", cover: true))
        await waitUntil { counter.count >= 2 }

        #expect(counter.count == 2)  // A different book triggers exactly one more fetch
    }

    // MARK: - Stale artwork regressions (#58)

    /// Provider whose per-URL responses are completed manually, in any order.
    @MainActor private final class GatedProvider {
        var waiters: [URL: CheckedContinuation<Data?, Never>] = [:]
        func fetch(_ url: URL) async -> Data? {
            await withCheckedContinuation { waiters[url] = $0 }
        }
        func complete(_ url: URL, with data: Data?) { waiters.removeValue(forKey: url)?.resume(returning: data) }
    }

    private func makeCoordinator(_ bridge: NoopPlaybackBridge) -> PlaybackCoordinator {
        let db = AppDatabase.makeTemporaryDatabase(named: "art-stale-\(UUID().uuidString)")
        return PlaybackCoordinator(engine: FakeAudioEngine(), positionStore: SQLitePositionStore(database: db), bridge: bridge)
    }

    @Test func delayedArtworkForPreviousBookIsDiscarded() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        let gate = GatedProvider()
        coordinator.artworkProvider = { await gate.fetch($0) }
        let a = makeBook(title: "A", cover: true), b = makeBook(title: "B", cover: true)

        await coordinator.play(a)
        await waitUntil { gate.waiters[a.book.coverURL!] != nil }
        await coordinator.play(b)
        await waitUntil { gate.waiters[b.book.coverURL!] != nil }
        gate.complete(a.book.coverURL!, with: Data([0xAA]))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(bridge.lastArtworkData == .some(nil))  // B shows the neutral placeholder, never A's cover
        gate.complete(b.book.coverURL!, with: Data([0xBB]))
        await waitUntil { bridge.lastArtworkData == .some(Data([0xBB])) }
        #expect(bridge.lastArtworkData == .some(Data([0xBB])))
        #expect(bridge.lastNowPlaying?.albumTitle == "B")
    }

    @Test func cachedCoverShowsImmediatelyOnSwitch() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        let counter = FetchCounter()
        coordinator.artworkProvider = { _ in counter.count += 1; return nil }
        let a = makeBook(title: "A", cover: true), b = makeBook(title: "B", cover: true)
        let bCover = Data([0xBB])
        coordinator.cachedArtworkProvider = { $0 == b.book.coverURL ? bCover : nil }

        await coordinator.play(a)
        await coordinator.play(b)

        #expect(bridge.lastArtworkData == .some(bCover))
        #expect(counter.count == 1)  // Only A needed a fetch
    }

    @Test func missingCoverClearsPreviousBooksArtwork() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        coordinator.artworkProvider = { _ in self.coverData }
        await coordinator.play(makeBook(title: "A", cover: true))
        await waitUntil { bridge.lastArtworkData == .some(self.coverData) }

        await coordinator.play(makeBook(title: "B", cover: false))

        #expect(bridge.lastArtworkData == .some(nil))
    }

    @Test func failedFetchKeepsCurrentIdentityAndPlaceholder() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        let gate = GatedProvider()
        coordinator.artworkProvider = { await gate.fetch($0) }
        let a = makeBook(title: "A", cover: true)
        await coordinator.play(a)
        await waitUntil { gate.waiters[a.book.coverURL!] != nil }
        gate.complete(a.book.coverURL!, with: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(bridge.lastArtworkData == .some(nil))
        #expect(bridge.lastNowPlaying?.albumTitle == "A")
    }

    @Test func rapidSwitchingPublishesOnlyCurrentBooksArtwork() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        let gate = GatedProvider()
        coordinator.artworkProvider = { await gate.fetch($0) }
        let a = makeBook(title: "A", cover: true), b = makeBook(title: "B", cover: true)
        let aURL = a.book.coverURL!, bURL = b.book.coverURL!

        await coordinator.play(a)
        await waitUntil { gate.waiters[aURL] != nil }
        await coordinator.play(b)
        await waitUntil { gate.waiters[bURL] != nil }
        let firstA = gate.waiters.removeValue(forKey: aURL)
        await coordinator.play(a)
        await waitUntil { gate.waiters[aURL] != nil }

        // Out of order: B (stale) finishes first, then the newest A, then the old A.
        gate.complete(bURL, with: Data([0xBB]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(bridge.lastArtworkData == .some(nil))
        gate.complete(aURL, with: Data([0xAA]))
        await waitUntil { bridge.lastArtworkData == .some(Data([0xAA])) }
        firstA?.resume(returning: Data([0xAA]))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(bridge.lastArtworkData == .some(Data([0xAA])))
        #expect(bridge.lastNowPlaying?.albumTitle == "A")
    }

    @Test func metadataFieldsBelongToSameSession() async {
        let bridge = NoopPlaybackBridge()
        let coordinator = makeCoordinator(bridge)
        let b = makeBook(title: "B", cover: false)
        await coordinator.play(makeBook(title: "A", cover: false))
        await coordinator.play(b)
        let info = bridge.lastNowPlaying
        #expect(info?.albumTitle == "B")
        #expect(info?.title == b.chapters[0].title)
        #expect(info?.artist == b.book.authorLine)
        #expect(bridge.lastLiveActivity?.bookID == b.book.id)
    }
}
