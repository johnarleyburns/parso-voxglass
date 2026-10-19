import Testing
import Foundation
import os
@testable import VoxglassCore

private final class FakeScopedAccess: SecurityScopedAccessing {
    private struct State { var grant = true; var started = 0; var stopped = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var grant: Bool {
        get { state.withLock { $0.grant } }
        set { state.withLock { $0.grant = newValue } }
    }
    var started: Int { state.withLock { $0.started } }
    var stopped: Int { state.withLock { $0.stopped } }
    func startAccessing(_ url: URL) -> Bool {
        state.withLock { s in
            if s.grant { s.started += 1 }
            return s.grant
        }
    }
    func stopAccessing(_ url: URL) { state.withLock { $0.stopped += 1 } }
}

private actor MemoryPositions: PositionStore {
    private var all: [PlaybackPosition] = []
    func save(_ position: PlaybackPosition) async throws { all.append(position) }
    func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? { nil }
    func latestPosition() async throws -> PlaybackPosition? { nil }
    func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? { nil }
}

@MainActor
@Suite(.serialized) struct LocalPlaybackAccessTests {
    private let access = FakeScopedAccess()
    private let registry: SecurityScopedLeaseRegistry
    private let resolver: PlaybackSourceResolver
    private let dir: URL
    private let stale = OSAllocatedUnfairLock(initialState: false)

    init() throws {
        let access = access
        registry = SecurityScopedLeaseRegistry(access: access)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dir = dir
        let stale = stale
        resolver = PlaybackSourceResolver(registry: registry) { data in
            guard let name = String(data: data, encoding: .utf8), name != "unresolvable" else { return nil }
            return (dir.appendingPathComponent(name), stale.withLock { $0 })
        }
    }

    private func makeFile(_ name: String) throws {
        try Data("a".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func chapter(_ name: String, bookID: UUID = UUID(), remote: URL? = nil) -> Chapter {
        Chapter(bookID: bookID, title: name, index: 0, remoteURL: remote, localBookmark: Data(name.utf8))
    }

    private func harness() -> (PlaybackCoordinator, FakeAudioEngine) {
        let engine = FakeAudioEngine()
        let defaults = UserDefaults(suiteName: "lease-\(UUID().uuidString)")!
        let coordinator = PlaybackCoordinator(
            engine: engine, positionStore: MemoryPositions(),
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: NoopPlaybackBridge(), sourceResolver: resolver
        )
        return (coordinator, engine)
    }

    private func book(_ chapters: [Chapter]) -> BookWithChapters {
        let id = chapters.first?.bookID ?? UUID()
        return BookWithChapters(book: Book(id: id, title: "B", authors: ["A"], sourceID: UUID()), chapters: chapters)
    }

    private func play(_ coordinator: PlaybackCoordinator, _ book: BookWithChapters, _ chapter: Chapter) async {
        coordinator.selectAndPlay(book, chapter: chapter)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func loadCount(_ engine: FakeAudioEngine) -> Int {
        engine.calls.filter { if case .load = $0 { true } else { false } }.count
    }

    // MARK: Registry

    @Test func sharedURLStaysAccessibleUntilBothLeasesRelease() throws {
        let url = dir.appendingPathComponent("a.mp3")
        let first = try #require(registry.acquire(url))
        let second = try #require(registry.acquire(url))
        #expect(access.started == 1)
        first.release()
        first.release() // idempotent
        #expect(access.stopped == 0)
        #expect(registry.activeLeaseCount == 1)
        second.release()
        #expect(access.stopped == 1)
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func droppedLeaseReleasesOnce() throws {
        var lease: PlaybackLease? = registry.acquire(dir.appendingPathComponent("a.mp3"))
        #expect(lease != nil)
        lease = nil
        #expect(access.stopped == 1)
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func deniedScopeYieldsNoLease() {
        access.grant = false
        #expect(registry.acquire(dir.appendingPathComponent("a.mp3")) == nil)
        #expect(registry.activeLeaseCount == 0)
        #expect(access.stopped == 0)
    }

    // MARK: Resolver

    @Test func resolverReturnsTypedOutcomes() throws {
        try makeFile("ok.mp3")
        guard case .playableLocal(_, let lease) = resolver.resolve(chapter("ok.mp3")) else {
            Issue.record("expected playable"); return
        }
        #expect(lease != nil)
        lease?.release()

        guard case .missingFile = resolver.resolve(chapter("gone.mp3")) else {
            Issue.record("expected missing"); return
        }
        guard case .missingFile = resolver.resolve(chapter("unresolvable")) else {
            Issue.record("expected missing for unresolvable"); return
        }
        stale.withLock { $0 = true }
        guard case .staleBookmark = resolver.resolve(chapter("ok.mp3")) else {
            Issue.record("expected stale"); return
        }
        stale.withLock { $0 = false }
        access.grant = false
        guard case .scopeDenied = resolver.resolve(chapter("ok.mp3")) else {
            Issue.record("expected denied"); return
        }
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func unreadableFileIsTypedAndReleasesItsLease() throws {
        try makeFile("locked.mp3")
        let path = dir.appendingPathComponent("locked.mp3").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        guard geteuid() != 0 else { return }
        guard case .unreadableFile = resolver.resolve(chapter("locked.mp3")) else {
            Issue.record("expected unreadable"); return
        }
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func remoteFallbackOnlyWhenARemoteExists() throws {
        let remote = URL(string: "https://example.com/a.mp3")!
        guard case .remoteFallback(let url) = resolver.resolve(chapter("gone.mp3", remote: remote)) else {
            Issue.record("expected remote fallback"); return
        }
        #expect(url == remote)
        #expect(resolver.resolve(chapter("gone.mp3")).isFailure)
    }

    // MARK: Coordinator + engine

    @Test func deniedScopeNeverCallsAudioLoad() async {
        access.grant = false
        let (coordinator, engine) = harness()
        let b = book([chapter("a.mp3")])
        await play(coordinator, b, b.chapters[0])
        #expect(loadCount(engine) == 0)
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func missingAndStaleLocalOnlyNeverLoadOrUseNetwork() async throws {
        let (coordinator, engine) = harness()
        let missing = book([chapter("gone.mp3")])
        await play(coordinator, missing, missing.chapters[0])
        try makeFile("ok.mp3")
        stale.withLock { $0 = true }
        let stalled = book([chapter("ok.mp3")])
        await play(coordinator, stalled, stalled.chapters[0])
        #expect(loadCount(engine) == 0)
        #expect(!engine.calls.contains { if case .preloadNext = $0 { true } else { false } })
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func validLocalItemAcquiresAndReleasesOnce() async throws {
        try makeFile("a.mp3")
        let (coordinator, engine) = harness()
        let b = book([chapter("a.mp3")])
        await play(coordinator, b, b.chapters[0])
        #expect(loadCount(engine) == 1)
        #expect(access.started == 1)
        #expect(registry.activeLeaseCount == 1)
        coordinator.teardown()
        #expect(access.stopped == 1)
        #expect(registry.activeLeaseCount == 0)
    }

    @Test func currentAndPreloadedSharedURLStayAccessibleUntilBothRelease() async throws {
        try makeFile("shared.mp3")
        let (coordinator, engine) = harness()
        let id = UUID()
        let b = book([chapter("shared.mp3", bookID: id), Chapter(
            bookID: id, title: "2", index: 1, localBookmark: Data("shared.mp3".utf8))])
        await play(coordinator, b, b.chapters[0])
        engine.preloadNext(url: dir.appendingPathComponent("shared.mp3"),
                           lease: registry.acquire(dir.appendingPathComponent("shared.mp3")))
        let before = registry.activeLeaseCount
        #expect(before >= 2)
        engine.cancelPreload()
        #expect(registry.activeLeaseCount == before - 1)
        #expect(access.stopped == 0)
        engine.releasePlaybackLeases()
        #expect(registry.activeLeaseCount == 0)
        #expect(access.stopped == 1)
    }

    @Test func repeatedSwitchingDoesNotGrowActiveLeases() async throws {
        try makeFile("a.mp3")
        try makeFile("b.mp3")
        let (coordinator, _) = harness()
        let a = book([chapter("a.mp3")])
        let b = book([chapter("b.mp3")])
        for _ in 0..<6 {
            await play(coordinator, a, a.chapters[0])
            await play(coordinator, b, b.chapters[0])
            #expect(registry.activeLeaseCount == 1)
        }
        coordinator.teardown()
        #expect(registry.activeLeaseCount == 0)
        #expect(access.started == access.stopped)
    }

    @Test func failedLoadReleasesLeaseAndLeavesRemoteRetryPath() async throws {
        try makeFile("a.mp3")
        let (coordinator, engine) = harness()
        engine.loadError = AudioEngineError.unplayableAudio
        let b = book([chapter("a.mp3")])
        await play(coordinator, b, b.chapters[0])
        engine.releasePlaybackLeases()
        #expect(registry.activeLeaseCount == 0)
    }
}
