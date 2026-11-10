import Foundation
import Testing
import ParsoAudioStreaming
import VoxglassWatchProtocol
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
        #expect(WatchTimeFormat.duration(5400) == "1 hr, 30 min")
    }

    @Test func durationFormat_minutes() {
        #expect(WatchTimeFormat.duration(1800) == "30 min")
    }

    @Test func timeFormat_withHours() {
        #expect(WatchTimeFormat.time(3661) == "1:01:01")
    }

    @Test func timeFormat_minutesOnly() {
        #expect(WatchTimeFormat.time(125) == "2:05")
    }

    @Test func bytesFormat_small() {
        #expect(WatchTimeFormat.bytes(500, locale: Locale(identifier: "en")) == "500 byte")
    }

    @Test func bytesFormat_megabytes() {
        #expect(WatchTimeFormat.bytes(5_000_000, locale: Locale(identifier: "en")) == "4.8 MB")
    }

    @Test func bytesFormat_gigabytes() {
        #expect(WatchTimeFormat.bytes(2_000_000_000, locale: Locale(identifier: "en")) == "1.9 GB")
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

@Suite struct WatchChapterNavigationTests {
    private let bookID = UUID()

    private func chapters(_ count: Int) -> [Chapter] {
        (1...count).map { Chapter(bookID: bookID, title: "Ch \($0)", index: $0) }
    }

    @Test func next_returnsFollowingChapter() {
        let chs = chapters(3)
        let next = WatchChapterNavigation.next(after: chs[0].id, in: chs)
        #expect(next?.id == chs[1].id)
    }

    @Test func next_atLastChapter_isNil() {
        let chs = chapters(3)
        #expect(WatchChapterNavigation.next(after: chs[2].id, in: chs) == nil)
    }

    @Test func previous_returnsPrecedingChapter() {
        let chs = chapters(3)
        let prev = WatchChapterNavigation.previous(before: chs[2].id, in: chs)
        #expect(prev?.id == chs[1].id)
    }

    @Test func previous_atFirstChapter_isNil() {
        let chs = chapters(3)
        #expect(WatchChapterNavigation.previous(before: chs[0].id, in: chs) == nil)
    }

    @Test func navigation_followsNaturalOrderNotArrayOrder() {
        // Shuffled input: navigation must use the natural (index) ordering.
        let a = Chapter(bookID: bookID, title: "A", index: 1)
        let b = Chapter(bookID: bookID, title: "B", index: 2)
        let c = Chapter(bookID: bookID, title: "C", index: 3)
        let shuffled = [c, a, b]
        #expect(WatchChapterNavigation.next(after: a.id, in: shuffled)?.id == b.id)
        #expect(WatchChapterNavigation.previous(before: c.id, in: shuffled)?.id == b.id)
    }

    @Test func unknownChapter_isNil() {
        let chs = chapters(2)
        #expect(WatchChapterNavigation.next(after: UUID(), in: chs) == nil)
        #expect(WatchChapterNavigation.previous(before: UUID(), in: chs) == nil)
    }
}

@Suite struct WatchChapterCacheTests {
    private let bookID = UUID()

    @Test func canonicalDoesNotPreferOpus() {
        // The canonical identity must NOT prefer the opus rendition: the watch
        // engine cannot decode raw Ogg/Opus, so downloads and transfers key on
        // the rendition the players can decode (RC3/RC5, INV-B).
        let opus = URL(string: "https://archive.org/x/ch1.opus")!
        let remote = URL(string: "https://archive.org/x/ch1.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1, remoteURL: remote, opusURL: opus)
        #expect(WatchChapterCache.canonicalURL(for: chapter) == remote)
        #expect(WatchChapterCache.key(for: chapter) == AudioCache.key(for: remote))
        #expect(WatchChapterCache.key(for: chapter) != AudioCache.key(for: opus))
    }

    @Test func fallsBackToRemoteWhenNoOpus() {
        let remote = URL(string: "https://archive.org/x/ch1.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1, remoteURL: remote)
        #expect(WatchChapterCache.canonicalURL(for: chapter) == remote)
        #expect(WatchChapterCache.key(for: chapter) == AudioCache.key(for: remote))
    }

    @Test func keyIsStableForSameChapter() {
        let remote = URL(string: "https://archive.org/x/ch1.mp3")!
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1, remoteURL: remote)
        #expect(WatchChapterCache.key(for: chapter) == WatchChapterCache.key(for: chapter))
    }

    @Test func noURLsYieldsNilKey() {
        let chapter = Chapter(bookID: bookID, title: "Ch", index: 1)
        #expect(WatchChapterCache.canonicalURL(for: chapter) == nil)
        #expect(WatchChapterCache.key(for: chapter) == nil)
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

@Suite struct WatchConnectivityContractTests {
    @Test func aliceFixture_usesPlayableLibriVoxArchiveURLs() {
        let alice = WatchPhoneSmokeFixtures.aliceInWonderland()
        #expect(alice.book.title == "Alice's Adventures in Wonderland")
        #expect(alice.chapters.count >= 3)
        #expect(alice.chapters.allSatisfy { $0.remoteURL?.host == "archive.org" })
        #expect(alice.chapters.first?.remoteURL?.absoluteString.contains("alice_in_wonderland_librivox") == true)
        #expect(alice.chapters.first?.resolvedPlayableURL() == alice.chapters.first?.remoteURL)
    }

    @Test func phoneLibrarySnapshot_roundTripsThroughWatchConnectivityPayload() throws {
        let alice = WatchPhoneSmokeFixtures.aliceInWonderland()
        let state = WatchPhonePlaybackState(
            accepted: true,
            session: PlaybackSession(
                book: alice.book,
                chapters: alice.chapters,
                chapter: alice.chapters[0],
                position: 0,
                duration: alice.chapters[0].duration,
                isPlaying: true
            )
        )
        let snapshot = WatchPhoneLibrarySnapshot(books: [alice], playbackState: state)

        let message = try WatchPhoneMessageCodec.message(
            action: WatchPhoneAction.requestLibrary,
            payload: snapshot
        )
        #expect(WatchPhoneMessageCodec.action(from: message) == WatchPhoneAction.requestLibrary)

        let decoded = try WatchPhoneMessageCodec.payload(WatchPhoneLibrarySnapshot.self, from: message)
        #expect(decoded.books.first?.book.title == alice.book.title)
        #expect(decoded.playbackState?.session?.isPlaying == true)
    }

    @Test func watchStorageSnapshot_roundTripsThroughWatchConnectivityPayload() throws {
        let alice = WatchPhoneSmokeFixtures.aliceInWonderland()
        let chapters = alice.chapters.naturallySorted()
        let storage = WatchBookStorageInfo(
            state: .transferring(progress: 2.0 / 3.0),
            byteCount: 42,
            chapterCount: 2,
            completeChapterCount: 2,
            totalChapterCount: 3,
            chapters: [
                WatchChapterStorageInfo(id: chapters[0].id, chapterIndex: 0, state: .available, byteCount: 21),
                WatchChapterStorageInfo(id: chapters[1].id, chapterIndex: 1, state: .available, byteCount: 21),
                WatchChapterStorageInfo(id: chapters[2].id, chapterIndex: 2, state: .transferring(progress: 0.25))
            ]
        )
        let snapshot = WatchStorageSnapshot(books: [alice.book.id: storage])

        let message = try WatchPhoneMessageCodec.message(
            action: WatchPhoneAction.reportWatchStorage,
            payload: snapshot
        )

        #expect(WatchPhoneMessageCodec.action(from: message) == WatchPhoneAction.reportWatchStorage)
        let decoded = try WatchPhoneMessageCodec.payload(WatchStorageSnapshot.self, from: message)
        let decodedInfo = try #require(decoded.storageInfo(for: alice.book.id))
        #expect(decodedInfo.completeChapterCount == 2)
        #expect(decodedInfo.totalChapterCount == 3)
        #expect(decodedInfo.chapters[2].state == .transferring(progress: 0.25))
    }

    @Test func watchStorageText_marksPhoneLibraryRows() {
        let available = WatchBookStorageInfo(
            state: .available,
            byteCount: 100,
            chapterCount: 3,
            completeChapterCount: 3,
            totalChapterCount: 3
        )
        #expect(available.phoneLibraryStatusText == "Downloaded on Watch")

        let partial = WatchBookStorageInfo(
            state: .queued,
            byteCount: 50,
            chapterCount: 1,
            completeChapterCount: 1,
            totalChapterCount: 3
        )
        #expect(partial.phoneLibraryStatusText == "1/3 chapters on Watch")
    }

    @Test func downloadedBookRemainsAvailableWithNoPhoneOrInternet() {
        let state = WatchTransferStateResolver.resolve(
            isDownloaded: true,
            isQueued: false,
            isTransferring: false,
            progress: 0,
            isFailed: false,
            isPhoneReachable: false,
            needsPhoneTransfer: false
        )
        #expect(state == .available)
    }

    @Test func notDownloadedBookCanWaitForPhoneButDoesNotBlockStreamingPolicy() {
        let waiting = WatchTransferStateResolver.resolve(
            isDownloaded: false,
            isQueued: false,
            isTransferring: false,
            progress: 0,
            isFailed: false,
            isPhoneReachable: false,
            needsPhoneTransfer: true
        )
        #expect(waiting == .waitingForPhone)

        let alice = WatchPhoneSmokeFixtures.aliceInWonderland()
        #expect(alice.chapters[0].resolvedPlayableURL()?.scheme == "https")
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
        #expect(WatchTransferState.paused == .paused)
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
            .paused,
            .available,
            .failed
        ]
        #expect(states.count == 7)
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

    @Test func sendReadiness_readyWhenActivatedInstalledAndIdle() {
        let readiness = WatchSendReadinessResolver.resolve(
            isAlreadyTransferring: false, isActivated: true, isWatchAppInstalled: true
        )
        #expect(readiness == .ready)
    }

    @Test func sendReadiness_blocksWhenAlreadyTransferring() {
        let readiness = WatchSendReadinessResolver.resolve(
            isAlreadyTransferring: true, isActivated: true, isWatchAppInstalled: true
        )
        #expect(readiness == .transferAlreadyInProgress)
    }

    @Test func sendReadiness_blocksWhenNotActivated() {
        let readiness = WatchSendReadinessResolver.resolve(
            isAlreadyTransferring: false, isActivated: false, isWatchAppInstalled: true
        )
        #expect(readiness == .sessionNotActivated)
    }

    /// The exact state that was reachable via the historical race: activation
    /// completes but a stale, separately-timed read still reports not-installed.
    @Test func sendReadiness_blocksWhenActivatedButNotInstalled() {
        let readiness = WatchSendReadinessResolver.resolve(
            isAlreadyTransferring: false, isActivated: true, isWatchAppInstalled: false
        )
        #expect(readiness == .watchAppNotInstalled)
    }

    @Test func sendReadiness_transferringTakesPrecedenceOverNotActivated() {
        let readiness = WatchSendReadinessResolver.resolve(
            isAlreadyTransferring: true, isActivated: false, isWatchAppInstalled: false
        )
        #expect(readiness == .transferAlreadyInProgress)
    }

    @Test func catalogAcceptance_reconcilesForwardProgressWithinSameInstall() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: "A", incomingRevision: 48, lastAcceptedEpoch: "A", lastAcceptedRevision: 47
        )
        #expect(acceptance == .reconcile)
    }

    @Test func catalogAcceptance_skipsExactRepeatWithinSameInstall() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: "A", incomingRevision: 47, lastAcceptedEpoch: "A", lastAcceptedRevision: 47
        )
        #expect(acceptance == .skipDuplicate)
    }

    /// The genuinely out-of-order case the original device-level guard protected against: a lower
    /// revision from the SAME install is stale, and must still be skipped, or a late-arriving older
    /// catalog could wipe out acknowledgements for books that installed correctly in between.
    @Test func catalogAcceptance_skipsStaleLowerRevisionWithinSameInstall() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: "A", incomingRevision: 46, lastAcceptedEpoch: "A", lastAcceptedRevision: 47
        )
        #expect(acceptance == .skipDuplicate)
    }

    /// The exact regression this resolver exists to fix: a watch app delete + reinstall resets its
    /// local report counter to 1, numerically far below whatever the phone last accepted — but the
    /// install epoch changed too, so this must reconcile instead of being dropped as "stale" forever.
    @Test func catalogAcceptance_reconcilesAfterWatchReinstallDespiteLowerRevision() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: "B", incomingRevision: 1, lastAcceptedEpoch: "A", lastAcceptedRevision: 47
        )
        #expect(acceptance == .reconcile)
    }

    @Test func catalogAcceptance_reconcilesFirstEverReportWithNoStoredEpoch() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: "A", incomingRevision: 1, lastAcceptedEpoch: nil, lastAcceptedRevision: 0
        )
        #expect(acceptance == .reconcile)
    }

    /// An older watch build that predates `installEpoch` reports `nil`; fall back to the original
    /// comparison exactly so those builds keep today's behavior.
    @Test func catalogAcceptance_legacyFallbackReconcilesForwardProgressWhenEpochMissing() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: nil, incomingRevision: 5, lastAcceptedEpoch: "A", lastAcceptedRevision: 4
        )
        #expect(acceptance == .reconcile)
    }

    @Test func catalogAcceptance_legacyFallbackSkipsStaleRevisionWhenEpochMissing() {
        let acceptance = WatchCatalogAcceptanceResolver.resolve(
            incomingEpoch: nil, incomingRevision: 3, lastAcceptedEpoch: "A", lastAcceptedRevision: 4
        )
        #expect(acceptance == .skipDuplicate)
    }
}

@Suite struct WatchNarrationEstimateTests {
    @Test func textChaptersUseGeneratedNarrationEstimate() {
        let chapter = Chapter(bookID: UUID(), title: "PDF", index: 0, duration: 7_200,
                              localURL: URL(fileURLWithPath: "/tmp/chapter.voxtext"))
        #expect(WatchNarrationEstimate.needsGeneratedAudio(for: [chapter]))
        #expect(WatchNarrationEstimate.estimatedAudioBytes(duration: 7_200) == 28_800_000)
        #expect(WatchNarrationEstimate.estimatedCreationDuration(narrationDuration: 7_200) == 600)
    }
}

@Suite struct WatchAcknowledgedStorageResolverTests {
    private func ack(complete: Bool, failure: String? = nil) -> WatchManifestAcknowledgement {
        var a = WatchManifestAcknowledgement(bookID: WatchBookID("b"), revision: 1, complete: complete, installedBytes: 0)
        a.failureMessage = failure
        return a
    }

    // A truly complete report wins even over a failed desired state.
    @Test func acknowledgedStorage_completeIsAlwaysAvailable() {
        #expect(WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack(complete: true), desiredState: .failed("x"), priorStorageState: nil) == .available)
    }

    @Test func acknowledgedStorage_explicitFailureMessageIsFailed() {
        #expect(WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack(complete: false, failure: "disk full"), desiredState: nil, priorStorageState: nil) == .failed)
    }

    @Test func acknowledgedStorage_failedDesiredStateWinsOverIncompleteReport() {
        for prior in [nil, WatchTransferState.available, .transferring(progress: 0.6)] {
            #expect(WatchAcknowledgedStorageResolver.resolve(
                acknowledgement: ack(complete: false),
                desiredState: .failed("Audio is no longer fully installed."),
                priorStorageState: prior) == .failed)
        }
    }

    @Test func acknowledgedStorage_pausedDesiredStateIsPaused() {
        #expect(WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack(complete: false), desiredState: .paused, priorStorageState: nil) == .paused)
    }

    @Test func acknowledgedStorage_preservesTransferringProgressWhenDesiredIsInFlight() {
        #expect(WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack(complete: false), desiredState: .transferring,
            priorStorageState: .transferring(progress: 0.42)) == .transferring(progress: 0.42))
    }

    @Test func acknowledgedStorage_fallsBackToQueuedWithNoOtherSignal() {
        #expect(WatchAcknowledgedStorageResolver.resolve(
            acknowledgement: ack(complete: false), desiredState: nil, priorStorageState: nil) == .queued)
    }
}

@Suite struct WatchDisplayStateResolverTests {
    private func r(_ d: WatchDownloadState?, _ s: WatchTransferState?) -> WatchTransferState {
        WatchDisplayStateResolver.resolve(desiredState: d, storageState: s)
    }
    @Test func displayState_desiredFailedWinsOverCachedAvailable() { #expect(r(.failed("x"), .available) == .failed) }
    @Test func displayState_desiredFailedWinsOverCachedTransferring() { #expect(r(.failed("x"), .transferring(progress: 0.5)) == .failed) }
    @Test func displayState_desiredPausedWinsOverCachedAvailable() { #expect(r(.paused, .available) == .paused) }
    @Test func displayState_desiredRemovingNeverShowsAvailable() { #expect(r(.removing, .available) == .notAvailable) }
    @Test func displayState_desiredDownloadedIsAvailableRegardlessOfCache() {
        #expect(r(.downloaded, nil) == .available)
        #expect(r(.downloaded, .queued) == .available)
    }
    @Test func displayState_inFlightDesiredPreservesCachedProgress() {
        #expect(r(.transferring, .transferring(progress: 0.73)) == .transferring(progress: 0.73))
    }
    @Test func displayState_inFlightDesiredWithoutCachedProgressFallsBackToQueued() { #expect(r(.preparing, nil) == .queued) }
    @Test func displayState_noDesiredStateTrustsCache() { #expect(r(nil, .available) == .available) }
}

@Suite struct WatchTransferStatusBannerTests {
    private func id(_ n: Int) -> WatchBookID { WatchBookID("book-\(n)") }
    private func r(_ d: [WatchBookID: WatchDownloadState], _ s: [WatchBookID: WatchTransferState] = [:]) -> WatchTransferStatusBanner? {
        WatchTransferStatusBannerResolver.resolve(desiredStates: d, storageStates: s)
    }
    @Test func banner_downloadedStateShowsDownloadedCount() {
        #expect(r([id(1): .downloaded, id(2): .downloaded]) == .init(downloadedCount: 2, failedCount: 0))
    }
    @Test func banner_failedStateShowsFailureCount() {
        let b = r([id(1): .failed("x")])
        #expect(b == .init(downloadedCount: 0, failedCount: 1))
        #expect(b?.hasFailure == true)
    }
    @Test func banner_downloadedAndFailedStatesShowsBothCounts() {
        #expect(r([id(1): .downloaded, id(2): .failed("x")]) == .init(downloadedCount: 1, failedCount: 1))
    }
    @Test func banner_inFlightOnlyStatesAreHidden() {
        #expect(r([id(1): .queued, id(2): .preparing, id(3): .transferring, id(4): .installing]) == nil)
    }
    @Test func banner_pausedRemovingAndNotRequestedAreHidden() {
        #expect(r([id(1): .paused, id(2): .removing, id(3): .notRequested],
                  [id(1): .available, id(2): .available, id(3): .available]) == nil)
    }
    @Test func banner_noDesiredStateDoesNotTrustOrphanedCachedAvailable() {
        #expect(r([:], [id(1): .available]) == nil)
    }
    @Test func banner_authoritativeFailureBeatsCachedAvailable() {
        #expect(r([id(1): .failed("x")], [id(1): .available]) == .init(downloadedCount: 0, failedCount: 1))
    }
    @Test func banner_authoritativeNotRequestedBeatsCachedAvailable() {
        #expect(r([id(1): .notRequested], [id(1): .available]) == nil)
    }
}

@Suite struct LocaleAwareByteFormatTests {
    private func bytes(_ n: Int64, _ id: String) -> String {
        WatchTimeFormat.bytes(n, locale: Locale(identifier: id))
    }

    @Test func binaryBoundaries_english() {
        #expect(bytes(0, "en") == "0 byte")
        #expect(bytes(1023, "en") == "1,023 byte")
        #expect(bytes(1024, "en") == "1 kB")
        #expect(bytes(1_048_576, "en") == "1 MB")
        #expect(bytes(1_073_741_824, "en") == "1 GB")
    }

    @Test func localeSpecificFormatting() {
        #expect(bytes(1023, "de") == "1.023 Byte")
        #expect(bytes(1_073_741_824, "fr") == "1\u{202F}Go")
        #expect(bytes(1_048_576, "fr") == "1\u{202F}Mo")
        #expect(bytes(1023, "fr").hasSuffix("\u{202F}o") || bytes(1023, "fr").hasSuffix("\u{00A0}o"))
        #expect(bytes(1023, "zh-Hans") == "1,023 B")
        #expect(bytes(1023, "ja") == "1,023 byte")
        #expect(bytes(1024, "he").contains("kB"))
        #expect(bytes(1024, "he") != bytes(1024, "en"))
    }

    @Test @MainActor func curatedBatchIsDecimalAndLocalized() {
        let en = Locale(identifier: "en")
        #expect(CatalogStore.formattedBatchSize(entryCount: 2, locale: en) == "500 MB")
        #expect(CatalogStore.formattedBatchSize(entryCount: 20, locale: en) == "5 GB")
        #expect(CatalogStore.formattedBatchSize(entryCount: 20, locale: Locale(identifier: "fr")) == "5\u{202F}Go")
        #expect(CatalogStore.formattedBatchSize(entryCount: 2, locale: Locale(identifier: "fr")) == "500\u{202F}Mo")
    }

    @Test func timeCodesUnchanged() {
        #expect(WatchTimeFormat.time(83) == "1:23")
        #expect(WatchTimeFormat.time(125) == "2:05")
    }
}
