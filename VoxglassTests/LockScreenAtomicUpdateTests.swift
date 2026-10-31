import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite(.serialized) struct LockScreenAtomicUpdateTests {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let bridge: NoopPlaybackBridge
    }

    private actor MemoryPositionStore: PositionStore {
        private var positions: [PlaybackPosition] = []
        func save(_ position: PlaybackPosition) async throws { positions.append(position) }
        func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? {
            positions.last { $0.bookID == bookID && $0.chapterID == chapterID }
        }
        func latestPosition() async throws -> PlaybackPosition? { positions.last }
        func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? {
            positions.last { $0.bookID == bookID }
        }
    }

    private func makeHarness() -> Harness {
        let engine = FakeAudioEngine()
        let defaults = UserDefaults(suiteName: "lock-\(UUID().uuidString)")!
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: MemoryPositionStore(),
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        return Harness(coordinator: coordinator, engine: engine, bridge: bridge)
    }

    private func makeBook(title: String = "Book") -> BookWithChapters {
        let bookID = UUID()
        let chapters = (0..<2).map { index in
            Chapter(
                bookID: bookID, title: "Chapter \(index)", index: index, duration: 100,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
        return BookWithChapters(book: Book(id: bookID, title: title, authors: ["A"], sourceID: UUID()), chapters: chapters)
    }

    private func drain() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    @Test func playSubmitsNativeNowPlayingOnly() async {
        let h = makeHarness()
        await h.coordinator.play(makeBook())
        await drain()
        #expect(!h.bridge.lockScreenCalls.isEmpty)
        #expect(h.bridge.lastNowPlaying != nil)
    }

    @Test func pauseSubmitsOneNativeUpdate() async {
        let h = makeHarness()
        await h.coordinator.play(makeBook())
        await drain()
        let before = h.bridge.lockScreenCalls.count
        h.coordinator.pause()
        #expect(h.bridge.lockScreenCalls.count == before + 1)
        #expect(h.bridge.lastNowPlaying?.reportedRate == 0)
    }

    @Test func fullLifecycleRecordsNativeNowPlayingStates() async {
        let h = makeHarness()
        let first = makeBook(title: "One")
        await h.coordinator.play(first)
        await drain()
        #expect(h.bridge.lastNowPlaying != nil)
        h.coordinator.pause()
        #expect(h.bridge.lastNowPlaying != nil)
        await h.coordinator.seek(to: 10)
        await drain()
        #expect(h.bridge.lastNowPlaying != nil)
        h.coordinator.setPlaybackRate(1.5)
        await drain()
        #expect(h.bridge.lastNowPlaying != nil)
        let second = makeBook(title: "Two")
        await h.coordinator.play(second)
        await drain()
        #expect(h.bridge.lastNowPlaying != nil)
        await h.coordinator.tickProgress()
        h.coordinator.stopPlayback(forDeletedBook: second.book.id)
        #expect(h.bridge.lastNowPlaying == nil)
        #expect(!h.bridge.lockScreenCalls.isEmpty)
    }

    @Test func eachTransitionRecordsOneNativeNowPlayingState() async {
        let h = makeHarness()
        await h.coordinator.play(makeBook(title: "One"))
        await drain()
        #expect(h.bridge.lastNowPlaying?.reportedRate != 0)
        var count = h.bridge.lockScreenCalls.count
        h.coordinator.pause()
        #expect(h.bridge.lockScreenCalls.count == count + 1)
        #expect(h.bridge.lastNowPlaying?.reportedRate == 0)
        count = h.bridge.lockScreenCalls.count
        await h.coordinator.seek(to: 10)
        await drain()
        #expect(h.bridge.lockScreenCalls.count > count)
        #expect(h.bridge.lastNowPlaying != nil)
        h.coordinator.setPlaybackRate(1.5)
        await drain()
        #expect(h.bridge.lastNowPlaying != nil)
        let second = makeBook(title: "Two")
        await h.coordinator.play(second)
        await drain()
        #expect(h.bridge.lastNowPlaying?.albumTitle == "Two")
        h.coordinator.stopPlayback(forDeletedBook: second.book.id)
        #expect(h.bridge.lockScreenCalls.last! == nil)
    }

    @Test func coordinatorSourceHasNoSplitBridgePair() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Voxglass/Core/Playback/PlaybackCoordinator.swift"), encoding: .utf8)
        #expect(!source.contains("bridge.updateNowPlaying("))
        #expect(source.contains("bridge.updateLockScreen(nowPlaying: nil)"))
    }
}
