import Foundation
import Testing
@testable import VoxglassCore

private final class TestClock: Clock, @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_000)
    var now: Date { current }
    func advance(_ s: TimeInterval) { current = current.addingTimeInterval(s) }
}

@MainActor
private final class Harness {
    let clock = TestClock()
    var published: [WatchPreparationProgress] = []
    var cancelled: [UUID] = []
    var scheduledCount = 0
    var coalescer: WatchPreparationProgressCoalescer!
    init() {
        coalescer = WatchPreparationProgressCoalescer(
            clock: clock,
            scheduler: { [unowned self] _, _ in
                scheduledCount += 1
                return Task {}
            },
            publish: { [unowned self] in published.append($0) },
            publishCancelled: { [unowned self] in cancelled.append($0) }
        )
    }
    func event(_ book: UUID, _ n: Int, _ phase: WatchPreparationProgress.Phase = .preparing, detail: String? = nil) -> WatchPreparationProgress {
        .init(bookID: book, phase: phase, completed: n, total: 100, detail: detail)
    }
}

@MainActor
@Suite struct WatchPreparationProgressCoalescerTests {
    let book = UUID()

    @Test func firstEventPublishesImmediately() {
        let h = Harness()
        h.coalescer.submit(h.event(book, 0))
        #expect(h.published.count == 1)
    }

    @Test func intermediateEventsAreLimitedToFourPerSecond() {
        let h = Harness()
        for i in 0..<100 {
            h.coalescer.submit(h.event(book, i))
            h.clock.advance(0.01)
        }
        #expect(h.published.count <= 5)
        #expect(h.published.count >= 4)
    }

    @Test func phaseChangePublishesImmediately() {
        let h = Harness()
        h.coalescer.submit(h.event(book, 1, .downloading))
        h.coalescer.submit(h.event(book, 2, .preparing))
        #expect(h.published.count == 2)
    }

    @Test func finalSuccessFailureAndCancellationAlwaysPublish() {
        let h = Harness()
        h.coalescer.submit(h.event(book, 1))
        h.coalescer.submit(h.event(book, 100, .complete))
        #expect(h.published.last?.phase == .complete)
        h.coalescer.submit(h.event(book, 1))
        h.coalescer.submit(h.event(book, 2, .failed))
        #expect(h.published.last?.phase == .failed)
        h.coalescer.submit(h.event(book, 1))
        h.coalescer.cancel(bookID: book)
        #expect(h.cancelled == [book])
    }

    @Test func latestDetailWinsWithinCoalescedWindow() {
        let h = Harness()
        h.coalescer.submit(h.event(book, 1, detail: "a"))
        h.coalescer.submit(h.event(book, 2, detail: "b"))
        h.coalescer.submit(h.event(book, 3, detail: "c"))
        #expect(h.published.count == 1)
        #expect(h.scheduledCount == 1)
        h.coalescer.flush(bookID: book)
        #expect(h.published.last?.detail == "c")
    }

    @Test func separateBooksDoNotCoalesceIntoEachOther() {
        let h = Harness()
        let other = UUID()
        h.coalescer.submit(h.event(book, 1))
        h.coalescer.submit(h.event(other, 1))
        #expect(h.published.map(\.bookID) == [book, other])
    }

    @Test func cancellationDropsScheduledStaleUpdate() {
        let h = Harness()
        h.coalescer.submit(h.event(book, 1))
        h.coalescer.submit(h.event(book, 2))
        h.coalescer.cancel(bookID: book)
        h.coalescer.flush(bookID: book)
        #expect(h.published.count == 1)
    }

    @Test func existingTransferStateTransitionsRemainUnchanged() {
        let h = Harness()
        let phases: [WatchPreparationProgress.Phase] = [.downloading, .preparing, .transcoding, .committing, .complete]
        for (i, p) in phases.enumerated() { h.coalescer.submit(h.event(book, i, p)) }
        #expect(h.published.map(\.phase) == phases)
    }
}
