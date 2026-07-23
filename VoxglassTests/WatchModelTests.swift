import Foundation
import Testing
@testable import VoxglassCore

@Suite struct WatchPositionMergeTests {
    private let now = Date()
    private let past = Date(timeIntervalSinceNow: -3600)

    private func pos(
        bookID: UUID = UUID(),
        chapterID: UUID = UUID(),
        position: TimeInterval = 100,
        duration: TimeInterval? = 1200,
        updatedAt: Date = Date(),
        isFinished: Bool = false
    ) -> PlaybackPosition {
        PlaybackPosition(
            id: UUID(),
            bookID: bookID,
            chapterID: chapterID,
            position: position,
            duration: duration,
            updatedAt: updatedAt,
            isFinished: isFinished
        )
    }

    // preferredPosition and snapshotWins are @MainActor-isolated;
    // each test invokes them inside `await MainActor.run { ... }`.

    @Test func preferredPosition_bothNil_returnsNil() async {
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: nil, snapshot: nil)
            #expect(result == nil)
        }
    }

    @Test func preferredPosition_onlyRow_returnsRow() async {
        let row = pos(position: 50, updatedAt: now)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: nil)
            #expect(result?.position == 50)
        }
    }

    @Test func preferredPosition_onlySnapshot_returnsSnapshot() async {
        let snap = pos(position: 75, updatedAt: now)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: nil, snapshot: snap)
            #expect(result?.position == 75)
        }
    }

    @Test func preferredPosition_sameChapter_snapshotAheadWins() async {
        let bookID = UUID()
        let chapterID = UUID()
        let row = pos(bookID: bookID, chapterID: chapterID, position: 50, updatedAt: now)
        let snap = pos(bookID: bookID, chapterID: chapterID, position: 60, updatedAt: past)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: snap)
            #expect(result?.position == 60, "Snapshot >2s ahead wins regardless of timestamp")
        }
    }

    @Test func preferredPosition_sameChapter_rowNewerWithinEpsilon() async {
        let bookID = UUID()
        let chapterID = UUID()
        let row = pos(bookID: bookID, chapterID: chapterID, position: 100, updatedAt: now)
        let snap = pos(bookID: bookID, chapterID: chapterID, position: 101, updatedAt: past)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: snap)
            #expect(result?.position == 100, "Row wins when snapshot not >2s ahead and row newer")
        }
    }

    @Test func preferredPosition_sameChapter_snapshotNewerWins() async {
        let bookID = UUID()
        let chapterID = UUID()
        let row = pos(bookID: bookID, chapterID: chapterID, position: 50, updatedAt: past)
        let snap = pos(bookID: bookID, chapterID: chapterID, position: 51, updatedAt: now)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: snap)
            #expect(result?.position == 51, "Newer snapshot wins even if barely ahead")
        }
    }

    @Test func preferredPosition_differentBooks_newerWins() async {
        let row = pos(bookID: UUID(), chapterID: UUID(), position: 100, updatedAt: past)
        let snap = pos(bookID: UUID(), chapterID: UUID(), position: 200, updatedAt: now)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: snap)
            #expect(result?.position == 200)
        }
    }

    @Test func preferredPosition_differentBooks_rowNewerWins() async {
        let row = pos(bookID: UUID(), chapterID: UUID(), position: 300, updatedAt: now)
        let snap = pos(bookID: UUID(), chapterID: UUID(), position: 100, updatedAt: past)
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: row, snapshot: snap)
            #expect(result?.position == 300)
        }
    }

    @Test func snapshotWins_noRow_returnsTrue() async {
        await MainActor.run {
            #expect(PlaybackCoordinator.snapshotWins(row: nil, snapshot: pos()))
        }
    }

    @Test func snapshotWins_snapshotNewer() async {
        await MainActor.run {
            #expect(PlaybackCoordinator.snapshotWins(
                row: pos(updatedAt: past),
                snapshot: pos(updatedAt: now)
            ))
        }
    }

    @Test func snapshotWins_snapshotAheadByMoreThan2() async {
        await MainActor.run {
            #expect(PlaybackCoordinator.snapshotWins(
                row: pos(position: 50, updatedAt: now),
                snapshot: pos(position: 53, updatedAt: past)
            ))
        }
    }

    @Test func snapshotWins_rowWinsWhenCloseAndNewer() async {
        await MainActor.run {
            #expect(!PlaybackCoordinator.snapshotWins(
                row: pos(position: 50, updatedAt: now),
                snapshot: pos(position: 51, updatedAt: past)
            ))
        }
    }

    @Test func antiZeroGuard_beatsStaleZero() async {
        let bookID = UUID()
        let chapterID = UUID()
        let zeroPos = PlaybackPosition(
            bookID: bookID,
            chapterID: chapterID,
            position: 0,
            duration: 1200,
            updatedAt: now,
            isFinished: false
        )
        let realPos = PlaybackPosition(
            bookID: bookID,
            chapterID: chapterID,
            position: 100,
            duration: 1200,
            updatedAt: now.addingTimeInterval(1),
            isFinished: false
        )
        await MainActor.run {
            let result = PlaybackCoordinator.preferredPosition(row: realPos, snapshot: zeroPos)
            #expect(result?.position == 100, "Real position beats zero snapshot")
        }
    }
}

@Suite struct WatchDisplayModelTests {

    @Test func longTitle_fitsInTwoLines() {
        let longTitle = String(repeating: "Very Long Book Title ", count: 10)
        let book = Book(
            id: UUID(),
            title: longTitle,
            authors: ["Author Name"],
            sourceID: UUID()
        )
        let displayTitle = book.title
        #expect(!displayTitle.isEmpty)
        #expect(displayTitle.count > 50)
    }

    @Test func longNarrator_displayFormat() {
        let book = Book(
            id: UUID(),
            title: "Short Title",
            authors: ["Author"],
            narrators: Array(repeating: "A Very Long Narrator Name", count: 5),
            sourceID: UUID()
        )
        #expect(book.narratorLine != nil)
        #expect(book.narratorLine!.count > 40)
    }

    @Test func longSummary_scrolls() {
        let longSummary = String(repeating: "This is a very long description. ", count: 20)
        let book = Book(
            id: UUID(),
            title: "Book",
            authors: ["Author"],
            summary: longSummary,
            sourceID: UUID()
        )
        #expect(book.summary!.count > 100)
    }

    @Test func durationFormat_hours() {
        #expect(WatchTimeFormat.duration(5400) == "1h 30m")
    }

    @Test func durationFormat_minutes() {
        #expect(WatchTimeFormat.duration(1800) == "30m")
    }

    @Test func timeFormat_withHours() {
        #expect(WatchTimeFormat.time(3661) == "1:01:01")
    }

    @Test func timeFormat_minutesOnly() {
        #expect(WatchTimeFormat.time(125) == "2:05")
    }

    @Test func bytesFormat_small() {
        #expect(WatchTimeFormat.bytes(500) == "500 B")
    }

    @Test func bytesFormat_megabytes() {
        #expect(WatchTimeFormat.bytes(5_000_000) == "4.8 MB")
    }

    @Test func bytesFormat_gigabytes() {
        #expect(WatchTimeFormat.bytes(2_000_000_000) == "1.9 GB")
    }
}

@Suite struct WatchStorageModelTests {

    @Test func defaultBookCap() {
        #expect(WatchStoragePolicy.maxBooks == 5)
    }

    @Test func defaultByteCap() {
        #expect(WatchStoragePolicy.maxBytes == 2_000_000_000)
    }

    @Test func remainingSlots_whenEmpty() {
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 0) == 5)
    }

    @Test func remainingSlots_whenFull() {
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 5) == 0)
    }

    @Test func remainingSlots_whenOver() {
        #expect(WatchStoragePolicy.remainingBookSlots(currentCount: 7) == 0)
    }

    @Test func remainingBytes_whenEmpty() {
        #expect(WatchStoragePolicy.remainingBytes(currentBytes: 0) == 2_000_000_000)
    }

    @Test func remainingBytes_whenHalfFull() {
        #expect(WatchStoragePolicy.remainingBytes(currentBytes: 1_000_000_000) == 1_000_000_000)
    }
}

@Suite struct WatchEvictionTests {

    @Test func evictionOrder_excludesCurrentBook() {
        let currentID = UUID()
        let books: [(id: UUID, lastPlayedAt: Date)] = [
            (currentID, Date(timeIntervalSinceNow: -100)),
            (UUID(), Date(timeIntervalSinceNow: -200))
        ]
        let order = WatchEvictionPolicy.evictionOrder(books: books, currentBookID: currentID)
        #expect(order.count == 1)
        #expect(!order.contains(currentID))
    }

    @Test func evictionOrder_leastRecentlyPlayedFirst() {
        let older = UUID()
        let newer = UUID()
        let books: [(id: UUID, lastPlayedAt: Date)] = [
            (newer, Date(timeIntervalSinceNow: -100)),
            (older, Date(timeIntervalSinceNow: -500))
        ]
        let order = WatchEvictionPolicy.evictionOrder(books: books, currentBookID: nil)
        #expect(order.first == older)
        #expect(order.last == newer)
    }
}

@Suite struct WatchTransferStateMachineTests {

    @Test func initialState_isNotAvailable() {
        let info = WatchBookStorageInfo.notAvailable
        #expect(info.state == .notAvailable)
        #expect(info.byteCount == 0)
    }

    @Test func transferStateEquality() {
        #expect(WatchTransferState.notAvailable == .notAvailable)
        #expect(WatchTransferState.queued == .queued)
        #expect(WatchTransferState.waitingForPhone == .waitingForPhone)
        #expect(WatchTransferState.available == .available)
        #expect(WatchTransferState.failed == .failed)
    }

    @Test func transferProgress_changesWithProgress() {
        #expect(WatchTransferState.transferring(progress: 0.3) == .transferring(progress: 0.3))
        #expect(WatchTransferState.transferring(progress: 0.3) != .transferring(progress: 0.7))
    }

    @Test func allStatesPresent() {
        let states: [WatchTransferState] = [
            .notAvailable,
            .queued,
            .waitingForPhone,
            .transferring(progress: 0.5),
            .available,
            .failed
        ]
        #expect(states.count == 6)
    }

    @Test func resolver_downloadedAlwaysAvailable() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: true, isQueued: false, isTransferring: false,
            progress: 0, isFailed: false, isPhoneReachable: false,
            needsPhoneTransfer: true
        )
        #expect(state == .available)
    }

    @Test func resolver_failedStaysFailed() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: false, isQueued: false, isTransferring: true,
            progress: 0.5, isFailed: true, isPhoneReachable: true,
            needsPhoneTransfer: false
        )
        #expect(state == .failed)
    }

    @Test func resolver_transferringShowsProgress() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: false, isQueued: false, isTransferring: true,
            progress: 0.6, isFailed: false, isPhoneReachable: true,
            needsPhoneTransfer: false
        )
        #expect(state == .transferring(progress: 0.6))
    }

    @Test func resolver_phoneUnreachableWhenNeeded() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: false, isQueued: true, isTransferring: false,
            progress: 0, isFailed: false, isPhoneReachable: false,
            needsPhoneTransfer: true
        )
        #expect(state == .waitingForPhone)
    }

    @Test func resolver_queuedWhenPhoneReachable() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: false, isQueued: true, isTransferring: false,
            progress: 0, isFailed: false, isPhoneReachable: true,
            needsPhoneTransfer: true
        )
        #expect(state == .queued)
    }

    @Test func resolver_notQueuedWithoutTransfer() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: false, isQueued: false, isTransferring: false,
            progress: 0, isFailed: false, isPhoneReachable: true,
            needsPhoneTransfer: false
        )
        #expect(state == .notAvailable)
    }
}
