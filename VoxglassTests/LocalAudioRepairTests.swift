import Testing
import Foundation
import os
@testable import VoxglassCore

private final class RepairAccess: SecurityScopedAccessing {
    private let granted = OSAllocatedUnfairLock(initialState: true)
    var grant: Bool {
        get { granted.withLock { $0 } }
        set { granted.withLock { $0 = newValue } }
    }
    func startAccessing(_ url: URL) -> Bool { grant }
    func stopAccessing(_ url: URL) {}
}

private actor RepairPositions: PositionStore {
    func save(_ position: PlaybackPosition) async throws {}
    func position(for bookID: UUID, chapterID: UUID) async throws -> PlaybackPosition? { nil }
    func latestPosition() async throws -> PlaybackPosition? { nil }
    func latestPosition(forBookID bookID: UUID) async throws -> PlaybackPosition? { nil }
}

@MainActor
@Suite(.serialized) struct LocalAudioRepairTests {
    private let root: URL
    private let access = RepairAccess()
    private let repository: LibraryRepository
    private let database: AppDatabase

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = AppDatabase.makeTemporaryDatabase(named: "repair-\(UUID().uuidString)")
        repository = LibraryRepository(database: database)
        setEnvironment(duration: 600)
    }

    private func setEnvironment(duration: TimeInterval?, failTransaction: Bool = false) {
        repository.localRepairEnvironment = LocalAudioRepairEnvironment(
            access: access,
            makeBookmark: { Data($0.path.utf8) },
            probeDuration: { _ in duration },
            isSupportedAudio: { ["mp3", "m4b"].contains($0.pathExtension.lowercased()) },
            injectTransactionFailure: failTransaction
        )
    }

    private func folder(_ name: String, files: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files { try Data("a".utf8).write(to: dir.appendingPathComponent(file)) }
        return dir
    }

    /// Imports then strips every binding: the exact damaged state.
    private func seedDamaged(
        title: String = "Book", dir: URL, chapters: [(String, TimeInterval)], placeholder: Bool = false
    ) async throws -> BookWithChapters {
        let files = chapters.enumerated().map { index, entry in
            LocalAudioImport(
                url: dir.appendingPathComponent(entry.0 + ".mp3"), title: entry.0, sortKey: String(index),
                duration: 100, startTime: entry.1
            )
        }
        let imported = try await repository.importLocalFolder(folderURL: dir, folderName: title, files: files)
        let remote: DatabaseValue = placeholder ? .string("https://example.invalid/x.mp3") : .null
        try await database.execute(
            "UPDATE chapters SET local_url = NULL, local_bookmark = NULL, remote_url = ?, opus_url = NULL WHERE book_id = ?",
            [remote, .string(imported.book.id.uuidString)]
        )
        return try #require(try await repository.fetchLibrary().first { $0.book.id == imported.book.id })
    }

    private func remoteBook(remote: URL?) async throws -> BookWithChapters {
        let sourceID = UUID()
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, 'S', 'https://archive.org/details/abc', 0)",
            [.string(sourceID.uuidString), .string(SourceKind.internetArchive.rawValue)]
        )
        let bookID = UUID()
        let chapter = Chapter(bookID: bookID, title: "r", index: 0, remoteURL: remote)
        let book = Book(id: bookID, title: "R", authors: ["A"], sourceID: sourceID)
        try await repository.insert(book: book, chapters: [chapter], bookContentKey: "ia:abc")
        return BookWithChapters(book: book, chapters: [chapter])
    }

    private func snapshot() async throws -> [BookWithChapters] { try await repository.fetchLibrary() }

    private func harness() -> (PlaybackCoordinator, FakeAudioEngine) {
        let engine = FakeAudioEngine()
        let defaults = UserDefaults(suiteName: "repair-\(UUID().uuidString)")!
        let coordinator = PlaybackCoordinator(
            engine: engine, positionStore: RepairPositions(),
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults), bridge: NoopPlaybackBridge()
        )
        let repository = repository
        coordinator.localSourceContextProvider = { await repository.localSourceContext(bookID: $0) }
        return (coordinator, engine)
    }

    private func loadCount(_ engine: FakeAudioEngine) -> Int {
        engine.calls.filter { if case .load = $0 { true } else { false } }.count
    }

    /// Selection deliberately publishes its result asynchronously.  Do not use
    /// a fixed delay here: the full CI suite runs many independent tests and a
    /// loaded runner can legitimately take longer than an arbitrary sleep.
    /// Polling the observed state keeps this regression test deterministic while
    /// retaining a finite timeout when the failure is not actually published.
    private func waitForFailure(
        _ coordinator: PlaybackCoordinator,
        timeout: Duration = .seconds(2)
    ) async -> PlaybackFailure? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if case .failed(let failure) = coordinator.playbackPhase {
                return failure
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .failed(let failure) = coordinator.playbackPhase {
            return failure
        }
        return nil
    }

    // MARK: Playback classification

    @Test(arguments: [false, true]) func damagedLocalBookShowsReconnectAndNeverLoads(placeholder: Bool) async throws {
        let dir = try folder("a", files: ["one.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("one", 0)], placeholder: placeholder)
        let (coordinator, engine) = harness()
        coordinator.selectAndPlay(book, chapter: book.chapters[0])
        guard let failure = await waitForFailure(coordinator) else { Issue.record("expected failure"); return }
        #expect(failure.needsReconnect)
        #expect(failure.message == LocalPlaybackUnavailable.reconnectMessage)
        #expect(loadCount(engine) == 0)
        #expect(coordinator.currentSession?.chapter.id == book.chapters[0].id)
    }

    @Test func remoteMissingSourceIsDistinctAndNeverLoads() async throws {
        let (coordinator, engine) = harness()
        let book = try await remoteBook(remote: nil)
        let chapter = book.chapters[0]
        coordinator.selectAndPlay(book, chapter: chapter)
        guard let failure = await waitForFailure(coordinator) else { Issue.record("expected failure"); return }
        #expect(!failure.needsReconnect && !failure.needsReselect)
        #expect(failure.message == LocalPlaybackUnavailable.remoteSourceMessage)
        #expect(loadCount(engine) == 0)
    }

    // MARK: Repair

    @Test func sharedFileRepairPreservesIdentityAndOffsets() async throws {
        let dir = try folder("shared", files: ["whole.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("c1", 0), ("c2", 100), ("c3", 200)])
        let file = dir.appendingPathComponent("whole.mp3")
        guard case .preview(let preview) = await repository.repairLocalAudio(bookID: book.book.id, selection: file, mapping: nil) else {
            Issue.record("expected preview"); return
        }
        #expect(preview.layout == .sharedFile && preview.isComplete)
        let outcome = await repository.repairLocalAudio(bookID: book.book.id, selection: file, mapping: preview.proposed)
        #expect(outcome == .success(repaired: 3))
        let after = try #require(try await snapshot().first)
        #expect(after.chapters.map(\.id) == book.chapters.map(\.id))
        #expect(after.chapters.map(\.startTime) == [0, 100, 200])
        #expect(after.chapters.map(\.duration) == book.chapters.map(\.duration))
        #expect(after.chapters.allSatisfy { $0.localURL != nil && $0.localBookmark != nil })
        #expect(try await snapshot().count == 1)
        let context = await repository.localSourceContext(bookID: book.book.id)
        #expect(context == LocalSourceContext(isLocalImport: true, hasLocalBinding: true))
    }

    @Test func sharedFileTooShortIsRejectedWithoutWrites() async throws {
        let dir = try folder("short", files: ["whole.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("c1", 0), ("c2", 700)])
        setEnvironment(duration: 600)
        let file = dir.appendingPathComponent("whole.mp3")
        let before = try await snapshot()
        let mapping = Dictionary(uniqueKeysWithValues: book.chapters.map { ($0.id, file) })
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: file, mapping: mapping) == .invalidDuration)
        setEnvironment(duration: nil)
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: file, mapping: mapping) == .invalidDuration)
        #expect(try await snapshot() == before)
    }

    @Test func multiFileRepairMatchesByStemThenTitleAndIsolatesSameTitledBooks() async throws {
        let dirA = try folder("A", files: ["01-alpha.mp3", "02-beta.mp3", "extra.mp3"])
        let dirB = try folder("B", files: ["01-alpha.mp3", "02-beta.mp3"])
        let a = try await seedDamaged(dir: dirA, chapters: [("01-alpha", 0), ("02-beta", 0)])
        let b = try await seedDamaged(title: "Book", dir: dirB, chapters: [("01-alpha", 0), ("02-beta", 0)])
        let beforeB = try #require(try await snapshot().first { $0.book.id == b.book.id })
        guard case .preview(let preview) = await repository.repairLocalAudio(bookID: a.book.id, selection: dirA, mapping: nil) else {
            Issue.record("expected preview"); return
        }
        #expect(preview.layout == .multiFile && preview.isComplete && preview.proposed.count == 2)
        #expect(await repository.repairLocalAudio(bookID: a.book.id, selection: dirA, mapping: preview.proposed) == .success(repaired: 2))
        let library = try await snapshot()
        #expect(library.count == 2)
        let afterA = try #require(library.first { $0.book.id == a.book.id })
        #expect(afterA.chapters.map(\.id) == a.chapters.map(\.id))
        #expect(afterA.chapters[0].localURL?.lastPathComponent == "01-alpha.mp3")
        #expect(afterA.chapters[1].localURL?.lastPathComponent == "02-beta.mp3")
        #expect(library.first { $0.book.id == b.book.id } == beforeB)
    }

    @Test func ambiguousAndUnmatchedChaptersNeedExplicitMapping() async throws {
        let dir = try folder("amb", files: ["other.mp3"])
        for sub in ["s1", "s2"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
            try Data("a".utf8).write(to: dir.appendingPathComponent("\(sub)/ch1.mp3"))
        }
        let book = try await seedDamaged(dir: dir, chapters: [("ch1", 0), ("missing", 0)])
        guard case .preview(let preview) = await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: nil) else {
            Issue.record("expected preview"); return
        }
        #expect(!preview.isComplete)
        #expect(preview.proposed.isEmpty)
        #expect(preview.ambiguous.keys.contains(book.chapters[0].id))
        #expect(preview.unmatched == [book.chapters[1].id])
        let before = try await snapshot()
        // Incomplete mapping, and two chapters on one file, both refuse to write.
        let first = try #require(preview.ambiguous[book.chapters[0].id]?.first)
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: [book.chapters[0].id: first]) == .incompleteMapping)
        let dup = [book.chapters[0].id: first, book.chapters[1].id: first]
        if case .ambiguous = await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: dup) {} else {
            Issue.record("expected ambiguous")
        }
        #expect(try await snapshot() == before)
    }

    @Test func deniedCancelledAndTransactionFailureLeaveRowsUnchanged() async throws {
        let dir = try folder("fail", files: ["one.mp3", "two.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("one", 0), ("two", 0)])
        let before = try await snapshot()
        let mapping = [book.chapters[0].id: dir.appendingPathComponent("one.mp3"), book.chapters[1].id: dir.appendingPathComponent("two.mp3")]

        access.grant = false
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: mapping) == .denied)
        access.grant = true

        let task = Task { () -> LocalAudioRepairOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: mapping)
        }
        #expect(await task.value == .cancelled)

        setEnvironment(duration: 600, failTransaction: true)
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: mapping) == .error)
        #expect(try await snapshot() == before)
    }

    @Test func repairRefusesNonLocalBooks() async throws {
        let dir = try folder("remote", files: ["one.mp3"])
        let remote = try await remoteBook(remote: URL(string: "https://example.invalid/1.mp3"))
        let bookID = remote.book.id
        let chapter = remote.chapters[0]
        let outcome = await repository.repairLocalAudio(
            bookID: bookID, selection: dir, mapping: [chapter.id: dir.appendingPathComponent("one.mp3")]
        )
        #expect(outcome == .noMatch)
        #expect(try await snapshot().first { $0.book.id == bookID }?.chapters.first?.localURL == nil)
    }

    // MARK: Session reload

    @Test func reloadReseatsSameChapterAndPositionWithoutPlaying() async throws {
        let dir = try folder("reload", files: ["one.mp3", "two.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("one", 0), ("two", 0)])
        let (coordinator, engine) = harness()
        coordinator.selectAndPlay(book, chapter: book.chapters[1])
        try? await Task.sleep(nanoseconds: 200_000_000)
        let mapping = [book.chapters[0].id: dir.appendingPathComponent("one.mp3"), book.chapters[1].id: dir.appendingPathComponent("two.mp3")]
        #expect(await repository.repairLocalAudio(bookID: book.book.id, selection: dir, mapping: mapping) == .success(repaired: 2))
        let fresh = try #require(try await snapshot().first)
        #expect(coordinator.reloadSessionAfterRepair(fresh))
        #expect(coordinator.currentSession?.chapter.id == book.chapters[1].id)
        #expect(coordinator.currentSession?.chapter.localURL != nil)
        #expect(coordinator.playbackPhase == .paused)
        #expect(loadCount(engine) == 0)
    }

    @Test func lateRepairDoesNotReplaceUnrelatedSession() async throws {
        let dir = try folder("late", files: ["one.mp3"])
        let book = try await seedDamaged(dir: dir, chapters: [("one", 0)])
        let (coordinator, _) = harness()
        coordinator.selectAndPlay(book, chapter: book.chapters[0])
        try? await Task.sleep(nanoseconds: 200_000_000)
        let otherID = UUID()
        let other = Chapter(bookID: otherID, title: "o", index: 0, remoteURL: URL(string: "https://example.invalid/o.mp3"))
        let otherBook = BookWithChapters(book: Book(id: otherID, title: "O", authors: ["A"], sourceID: UUID()), chapters: [other])
        coordinator.selectAndPlay(otherBook, chapter: other)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!coordinator.reloadSessionAfterRepair(book))
        #expect(coordinator.currentSession?.book.id == otherID)
    }
}
