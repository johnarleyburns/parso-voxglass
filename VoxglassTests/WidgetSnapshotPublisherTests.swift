import Foundation
import Testing
@testable import VoxglassCore

private actor Recorder {
    var events: [String] = []
    var failWrites = false
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false
    private var entered: CheckedContinuation<Void, Never>?

    func log(_ e: String) { events.append(e) }
    func setFail(_ v: Bool) { failWrites = v }
    func enableGate() { gated = true }
    func waitUntilGateEntered() async {
        if gate != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func passGate() async {
        guard gated else { return }
        gated = false
        if let g = gate { gate = nil; g.resume() }
    }
    func gateIfNeeded() async {
        guard gated else { return }
        await withCheckedContinuation { c in
            gate = c
            entered?.resume(); entered = nil
        }
    }
}

private struct TestSink: SnapshotSink {
    let rec: Recorder
    func write(_ snapshot: NowPlayingSnapshot) async throws {
        await rec.gateIfNeeded()
        if await rec.failWrites { throw CocoaError(.fileWriteUnknown) }
        await rec.log("write:\(snapshot.chapterTitle)")
    }
    func remove() async throws { await rec.log("remove") }
}

private struct TestReloader: WidgetTimelineReloader {
    let rec: Recorder
    func reloadTimelines() async { await rec.log("reload") }
}

private func snap(chapter: String = "One", fraction: Double = 0.1, minutes: Int = 5, at: Double = 0) -> NowPlayingSnapshot {
    NowPlayingSnapshot(bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Book", author: "A", chapterEyebrow: nil, chapterTitle: chapter, fraction: fraction, minutesLeftInChapter: minutes, paletteIndex: 1, isPlaying: true, updatedAt: Date(timeIntervalSince1970: at))
}

private func make() -> (WidgetSnapshotPublisher, Recorder) {
    let rec = Recorder()
    return (WidgetSnapshotPublisher(sink: TestSink(rec: rec), reloader: TestReloader(rec: rec)), rec)
}

@Suite struct WidgetSnapshotPublisherTests {
    @Test func identicalDisplaySnapshotDoesNotWriteOrReload() async {
        let (p, rec) = make()
        await p.submit(snap()); await p.submit(snap())
        #expect(await rec.events == ["write:One", "reload"])
    }

    @Test func updatedAtAloneDoesNotWriteOrReload() async {
        let (p, rec) = make()
        await p.submit(snap(at: 1)); await p.submit(snap(at: 99))
        #expect(await rec.events == ["write:One", "reload"])
    }

    @Test func chapterChangeWritesThenReloadsOnce() async {
        let (p, rec) = make()
        await p.submit(snap()); await p.submit(snap(chapter: "Two"))
        #expect(await rec.events == ["write:One", "reload", "write:Two", "reload"])
    }

    @Test func minuteBoundaryWritesFreshRemainingTimeAndReloadsOnce() async {
        let (p, rec) = make()
        await p.submit(snap(minutes: 5)); await p.submit(snap(minutes: 4))
        #expect(await rec.events == ["write:One", "reload", "write:One", "reload"])
    }

    @Test func rapidPlaybackEventsCoalesceToLatestSnapshot() async {
        let (p, rec) = make()
        await rec.enableGate()
        let first = Task { await p.submit(snap(chapter: "A")) }
        await rec.waitUntilGateEntered()
        let b = Task { await p.submit(snap(chapter: "B")) }
        let c = Task { await p.submit(snap(chapter: "C")) }
        await b.value; await c.value
        await rec.passGate()
        await first.value
        #expect(await rec.events == ["write:A", "reload", "write:C", "reload"])
    }

    @Test func disableRemovesSnapshotAndReloadsOnce() async {
        let (p, rec) = make()
        await p.submit(snap())
        await p.submit(nil); await p.submit(nil)
        #expect(await rec.events == ["write:One", "reload", "remove", "reload"])
    }

    @Test func aSupersededBackgroundWriteCannotReplaceNewerSnapshot() async {
        let (p, rec) = make()
        await rec.enableGate()
        let first = Task { await p.submit(snap(chapter: "Old")) }
        await rec.waitUntilGateEntered()
        await p.submit(snap(chapter: "New"))
        await rec.passGate()
        await first.value
        #expect(await rec.events == ["write:Old", "reload", "write:New", "reload"])
    }

    @Test func failedWriteDoesNotReload() async {
        let (p, rec) = make()
        await rec.setFail(true)
        await p.submit(snap())
        #expect(await rec.events.isEmpty)
        await rec.setFail(false)
        await p.submit(snap())
        #expect(await rec.events == ["write:One", "reload"])
    }
}
