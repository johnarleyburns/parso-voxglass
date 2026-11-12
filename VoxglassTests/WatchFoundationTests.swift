import Foundation
import Testing
@testable import VoxglassWatchProtocol
@testable import VoxglassWatchCore
@testable import VoxglassCore

@Suite struct WatchFoundationTests {
    @Test func envelopeRoundTripsBinaryPropertyList() throws {
        let id: WatchPairedLibraryID = "library-a"
        let book: WatchBookDTO = .init(id: "book-1", title: "Alice", chapters: [.init(id: "chapter-1", index: 0, title: "One", duration: 12)])
        let data = try WatchProtocolEnvelope.encode(kind: .librarySnapshot, payload: WatchLibrarySnapshot(pairedLibraryID: id, revision: 4, books: [book]), libraryID: id, revision: 4)
        #expect(!data.isEmpty)
        let envelope = try WatchProtocolEnvelope.decode(data)
        #expect(envelope.kind == .librarySnapshot)
        #expect(try envelope.decodePayload(WatchLibrarySnapshot.self).books == [book])
    }

    @Test func playbackCheckpointUsesDurableUserInfoTransport() throws {
        let checkpoint = WatchPlaybackCheckpoint(bookID: "book", chapterID: "chapter", position: 42,
                                                 duration: 100, recordedAt: .distantPast)
        let data = try WatchProtocolEnvelope.encode(kind: .playbackSnapshot, payload: checkpoint,
                                                    libraryID: "library", revision: 3)
        let envelope = try WatchProtocolEnvelope.decode(data)
        #expect(WatchMessageKind.playbackSnapshot.channel == .userInfo)
        #expect(try envelope.decodePayload(WatchPlaybackCheckpoint.self) == checkpoint)
    }

    @Test func projectionRejectsOtherPairedLibraryAndPreservesDownloads() {
        var current = WatchStoreSnapshot(); current.pairedLibraryID = "library-a"; current.projectionRevision = 3
        let incoming = WatchLibrarySnapshot(pairedLibraryID: "library-b", revision: 4, books: [])
        #expect(WatchProjectionIngestor.apply(incoming, to: current) == .failure(.init(.wrongPair)))
    }

    @Test func connectionDebouncesDisconnect() {
        var reducer = WatchConnectionReducer(); let start = Date(timeIntervalSince1970: 100)
        reducer.activated(at: start); reducer.reachabilityChanged(false, at: start.addingTimeInterval(1))
        reducer.tick(at: start.addingTimeInterval(2.9)); #expect(reducer.state == .temporarilyUnavailable)
        reducer.tick(at: start.addingTimeInterval(3.1)); #expect(reducer.state == .unavailable)
    }

    @Test func fakeDuplexCanDuplicateAndFail() async throws {
        let link = WatchFakeDuplexLink(); let payload = Data("hello".utf8)
        var faults = WatchTransportFaults(); faults.duplicateNext = true; await link.setFaults(faults)
        try await link.phone.send(payload, over: .immediate)
        #expect(await link.watch.receive() == payload); #expect(await link.watch.receive() == payload)
        faults.failNext = true; await link.setFaults(faults)
        await #expect(throws: WatchProtocolFault.self) { try await link.phone.send(payload, over: .immediate) }
    }

    @Test func corruptStoreRecoversWithoutDeletingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = WatchStoreConfiguration(storeURL: root.appendingPathComponent("library.json"), audioDirectory: root.appendingPathComponent("audio"))
        try FileManager.default.createDirectory(at: config.audioDirectory, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: config.audioDirectory.appendingPathComponent("chapter.m4a"))
        try Data("not-json".utf8).write(to: config.storeURL)
        let result = await WatchStoreBootstrap.open(configuration: config)
        #expect(result.recovered); #expect(result.preservedFiles == ["chapter.m4a"]); #expect(result.store != nil)
    }
    @Test func phoneProjectionPreservesOrderOffsetsAndRejectsNonHTTPSStreams() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("shared.m4a")
        try Data("chapter bytes".utf8).write(to: audio)
        let bookID = UUID(); let sourceID = UUID()
        let book = Book(id: bookID, title: "Imported", authors: ["Author"], sourceID: sourceID)
        let chapters = [
            Chapter(bookID: bookID, title: "Second", index: 1, startTime: 12, duration: 8, remoteURL: URL(string: "http://private.example/2"), localURL: audio),
            Chapter(bookID: bookID, title: "First", index: 0, startTime: 0, duration: 12, remoteURL: URL(string: "https://public.example/1"), localURL: audio)
        ]
        let dto = PhoneWatchProjection.book(from: .init(book: book, chapters: chapters), revision: 7)
        #expect(dto.chapters.map(\.title) == ["First", "Second"])
        #expect(dto.chapters.map(\.startTime) == [0, 12])
        #expect(dto.chapters[0].approvedStreamURL?.scheme == "https")
        #expect(dto.chapters[1].approvedStreamURL == nil)
        #expect(dto.chapters.allSatisfy { $0.expectedBytes == 13 && $0.expectedSHA256 != nil })
    }

    @Test func phoneProjectionCarriesTheCurrentPhoneSavepoint() throws {
        let bookID = WatchBookID("book")
        let chapterID = WatchChapterID("chapter")
        let book = WatchBookDTO(id: bookID, title: "Book", chapters: [
            WatchChapterDTO(id: chapterID, index: 0, title: "Chapter", duration: 100)
        ])
        let snapshot = PhoneWatchProjection.applyingResumePosition(
            bookID: bookID, chapterID: chapterID, position: 42, to: WatchLibrarySnapshot(
                pairedLibraryID: "library", revision: 1, books: [book]
            )
        )
        #expect(snapshot.books[0].chapters[0].resumePosition == 42)
    }

    @MainActor private func resumeFixture(saved: (Int, TimeInterval, Bool)?) -> [Double?] {
        let bookID = UUID()
        let chapters = (0..<3).map { Chapter(bookID: bookID, title: "C\($0)", index: $0, startTime: 0, duration: 100) }
        let source = BookWithChapters(book: Book(id: bookID, title: "B", authors: [], sourceID: UUID()), chapters: chapters)
        let dto = WatchBookDTO(id: .init(bookID.uuidString), title: "B", chapters: chapters.map {
            WatchChapterDTO(id: .init($0.id.uuidString), index: $0.index, title: $0.title, duration: 100, resumePosition: 9)
        })
        let position = saved.map {
            PlaybackPosition(bookID: bookID, chapterID: chapters[$0.0].id, position: $0.1, duration: 100, isFinished: $0.2)
        }
        let result = PhoneWatchProjection.applyingResolvedResume(
            book: source, saved: position,
            to: WatchLibrarySnapshot(pairedLibraryID: "library", revision: 1, books: [dto])
        )
        return result.books[0].chapters.map(\.resumePosition)
    }

    @Test @MainActor func resolvedPhoneSavepointMarksOnlyItsLaterChapter() {
        #expect(resumeFixture(saved: (2, 42, false)) == [nil, nil, 42])
    }

    @Test @MainActor func finishedPhoneChapterSeedsTheNextChapterAtZero() {
        #expect(resumeFixture(saved: (1, 100, true)) == [nil, nil, 0])
    }

    @Test @MainActor func finalFinishedChapterRestartsAtFirstChapter() {
        #expect(resumeFixture(saved: (2, 100, true)) == [0, nil, nil])
    }

    @Test @MainActor func subStartFloorSavepointSeedsZeroAndMissingSeedsFirst() {
        #expect(resumeFixture(saved: (1, 2, false)) == [nil, 0, nil])
        #expect(resumeFixture(saved: nil) == [0, nil, nil])
    }

    @Test func installerCopiesStagesVerifiesAndAcknowledgesOnlyCompleteBooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)
        let id: WatchBookID = "book"
        let asset = WatchDownloadAsset(chapterID: "chapter", sourceURL: source, expectedBytes: 5, expectedSHA256: try WatchChecksum.sha256(of: source), filename: "chapter.m4a")
        let plan = WatchDownloadPlan(bookID: id, revision: 3, assets: [asset])
        let installer = WatchFileInstaller(durableRoot: root.appendingPathComponent("durable"))
        let acknowledgement = try await installer.install(plan: plan, availableBytes: 500 * 1024 * 1024)
        #expect(acknowledgement.complete)
        #expect(acknowledgement.installedBytes == 5)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("durable/book/chapter.m4a").path))
        await installer.remove(bookID: id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("durable/book").path))
    }

    @Test func installerRejectsBadChecksumAndReservePressure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        try Data("audio".utf8).write(to: source)
        let plan = WatchDownloadPlan(bookID: "book", revision: 1, assets: [WatchDownloadAsset(chapterID: "chapter", sourceURL: source, expectedBytes: 5, expectedSHA256: "bad", filename: "chapter")])
        let installer = WatchFileInstaller(durableRoot: root.appendingPathComponent("durable"))
        await #expect(throws: WatchDownloadPipelineError.checksumMismatch) { try await installer.install(plan: plan, availableBytes: 500 * 1024 * 1024) }
        await #expect(throws: WatchDownloadPipelineError.insufficientStorage(required: WatchStorageReserve.minimumBytes, available: 1)) { try await installer.install(plan: plan, availableBytes: 1) }
    }

    @Test func phoneAcknowledgementIsTheOnlyDownloadedTruthAndPersists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("projection.json")
        let store = PhoneWatchProjectionStore(url: url, libraryID: "library")
        let id: WatchBookID = "book"
        try await store.setDesired(.transferring, for: id)
        #expect(await store.isTruthfullyDownloaded(id) == false)
        try await store.acknowledge(.init(bookID: id, revision: 1, complete: true, installedBytes: 10))
        #expect(await store.isTruthfullyDownloaded(id))
        let relaunched = PhoneWatchProjectionStore(url: url, libraryID: "library")
        #expect(await relaunched.isTruthfullyDownloaded(id))
    }

    // MARK: WatchDownloadedFiles (off-MainActor reset/removal)

    private func tempRoot() throws -> (support: URL, root: URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("wdf-\(UUID().uuidString)", isDirectory: true)
        let root = support.appendingPathComponent("DownloadedBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (support, root)
    }

    private final class BlockingOps: WatchFileOperations, @unchecked Sendable {
        // Test double: state is guarded by the semaphores/lock below.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        private var _threadWasMain = false
        var threadWasMain: Bool { lock.lock(); defer { lock.unlock() }; return _threadWasMain }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func awaitEntered() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { self.entered.wait(); continuation.resume() }
            }
        }
        func remove(_ url: URL) throws {
            lock.lock(); _threadWasMain = Thread.isMainThread; lock.unlock()
            entered.signal(); release.wait()
            try FileManager.default.removeItem(at: url)
        }
    }

    private struct FailingOps: WatchFileOperations {
        func exists(_ url: URL) -> Bool { true }
        func remove(_ url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    }

    @Test func resetRemovesDownloadedBooksAndPlaybackFilesButNotNarrationOutbox() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("book"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("book/c.m4a"))
        for name in WatchDownloadedFiles.playbackFileNames + ["watch-narration-outbox.json"] {
            try Data("x".utf8).write(to: support.appendingPathComponent(name))
        }
        let result = try await WatchDownloadedFiles().resetDownloadedState(at: root)
        #expect(Set(result.removed) == Set(["DownloadedBooks"] + WatchDownloadedFiles.playbackFileNames))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("watch-narration-outbox.json").path))
    }

    @Test func resetFailureThrowsSoCallerKeepsPendingFlag() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        await #expect(throws: (any Error).self) {
            _ = try await WatchDownloadedFiles(operations: FailingOps()).resetDownloadedState(at: root)
        }
    }

    @Test func removeBookDeletesOnlyTheRequestedSafeBookDirectory() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        for id in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        }
        try await WatchDownloadedFiles().removeBook(bookID: "a", at: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path))
    }

    @Test func invalidBookIdentifierCannotEscapeDownloadsRoot() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        for bad in ["..", "../x", "a/b", ""] {
            await #expect(throws: (any Error).self) {
                try await WatchDownloadedFiles().removeBook(bookID: WatchBookID(bad), at: root)
            }
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func slowRemovalRunsOffMainThreadAndDoesNotBlockCaller() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        let ops = BlockingOps()
        let files = WatchDownloadedFiles(operations: ops)
        let task = Task { try await files.removeBook(bookID: "a", at: root) }
        await ops.awaitEntered()
        // The worker is blocked inside removeItem; this actor is still free to do other work.
        let state = await MainActor.run { "interaction-updated" }
        #expect(state == "interaction-updated")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        ops.release.signal()
        try await task.value
        #expect(!ops.threadWasMain)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }

    @Test func installAndRemoveAreSerializedWithoutPartialOrCrossBookOutput() async throws {
        let (support, root) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        let source = support.appendingPathComponent("src.m4a")
        let payload = Data("audio".utf8)
        try payload.write(to: source)
        let hash = try WatchChecksum.sha256(of: source)
        let ops = BlockingOps()
        let files = WatchDownloadedFiles(operations: ops)
        let removal = Task { try await files.removeBook(bookID: "a", at: root) }
        await ops.awaitEntered()
        let install = Task.detached {
            try files.install(source: source, root: root, bookID: "a", filename: "c.m4a",
                expectedBytes: Int64(payload.count), expectedSHA256: hash)
        }
        try await Task.sleep(for: .milliseconds(150))
        // Install must wait for the in-flight removal rather than interleave with it.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a/c.m4a").path))
        ops.release.signal()
        try await removal.value
        _ = try await install.value
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/c.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a/.incoming-c.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path))
    }
}

@Suite struct WatchTransferTruthfulnessTests {
    private func makeStore() -> PhoneWatchProjectionStore {
        PhoneWatchProjectionStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("p.json"), libraryID: "library")
    }

    @Test func submittingValidatedNarrationIsTransferringNotDownloaded() async throws {
        let store = makeStore(); let id: WatchBookID = "book"
        try await store.markSubmitted(id, at: Date(timeIntervalSince1970: 0))
        #expect((await store.current()).desired[id] == .transferring)
        #expect(!(await store.isTruthfullyDownloaded(id)))
        #expect(WatchTransferStatusCopy.resolve(state: .transferring, acknowledgement: nil)
            == "Sent to Apple Watch; waiting for Watch validation and installation.")
    }

    @Test func watchFormatRejectionMovesBookToFailedAndNeverDownloaded() async throws {
        let store = makeStore(); let id: WatchBookID = "book"
        try await store.markSubmitted(id, at: Date(timeIntervalSince1970: 0))
        var rejection = WatchManifestAcknowledgement(bookID: id, revision: 1, complete: false, installedBytes: 0)
        rejection.failureMessage = WatchTransferStatusCopy.watchRejection(
            chapterOrdinal: 2, reason: "The file isn’t in the correct format.")
        try await store.acknowledge(rejection)
        let state = await store.current()
        #expect(state.desired[id] == .failed(rejection.failureMessage!))
        #expect(!(await store.isTruthfullyDownloaded(id)))
        #expect(WatchTransferStatusCopy.resolve(state: state.desired[id], acknowledgement: rejection)
            == "Apple Watch rejected chapter 2: The file isn’t in the correct format.. The book was not installed.")
        #expect(!WatchTransferStatusCopy.isInstalled(state: state.desired[id], acknowledgement: rejection))
    }

    @Test func onlyCompleteAcknowledgementIsInstalled() {
        let ok = WatchManifestAcknowledgement(bookID: "b", revision: 1, complete: true, installedBytes: 1)
        #expect(WatchTransferStatusCopy.resolve(state: .downloaded, acknowledgement: ok) == "Installed on Apple Watch.")
        #expect(WatchTransferStatusCopy.resolve(state: .downloaded, acknowledgement: nil) != "Installed on Apple Watch.")
        #expect(WatchTransferStatusCopy.resolve(state: .preparing, acknowledgement: nil)
            == "Preparing AAC-LC narration for Apple Watch…")
        #expect(WatchTransferStatusCopy.isInstalled(state: .downloaded, acknowledgement: ok))
        #expect(WatchTransferStatusCopy.phoneValidationFailure(reason: "bad")
            == "Couldn’t prepare Apple Watch audio: generated narration is not a playable AAC-LC M4A. bad")
    }
}
