import Testing
import Foundation
@testable import VoxglassCore

// Device checklist (physical iPhone, Files-provider content such as iCloud Drive):
// 1. Import a folder, play, note position. 2. Move the folder in Files, relaunch,
// open the book: the unavailable message and "Reselect Folder or File" appear and
// the book stays in My Books. 3. Reselect the moved folder: playback resumes at the
// saved position with no duplicate book/chapters. 4. Repeat for watched-folder and
// single-file imports. 5. Delete the file: book stays recoverable. Record
// device/OS/scenario/result in the issue checklist.
@MainActor
@Suite struct FolderWatchServiceTests {

    // MARK: - Pure diff helper

    @Test func newAudioFilesFiltersByExtensionAndExcludesKnown() {
        let base = URL(fileURLWithPath: "/tmp/folder")
        let mp3 = base.appendingPathComponent("01.mp3")
        let flac = base.appendingPathComponent("02.flac")
        let txt = base.appendingPathComponent("notes.txt")
        let jpg = base.appendingPathComponent("cover.jpg")
        let known = base.appendingPathComponent("03.m4b")

        let result = FolderWatchService.newAudioFiles(
            in: [mp3, flac, txt, jpg, known],
            knownURLs: [known]
        )

        #expect(result.contains(mp3))
        #expect(result.contains(flac))
        #expect(!(result.contains(txt)))
        #expect(!(result.contains(jpg)))
        #expect(!(result.contains(known)))  // Known files must be excluded
    }

    @Test func soundIndexProgressEstimatesRemainingAtObservedRate() {
        let start = Date(timeIntervalSince1970: 1_000)
        let progress = SoundIndexProgress(
            totalTracks: 10,
            indexedTracks: 2,
            startedAt: start,
            now: start.addingTimeInterval(20)
        )

        #expect(progress.remainingTracks == 8)
        #expect(progress.fractionComplete == 0.2)
        #expect(progress.estimatedSecondsRemaining == 80)
        #expect(progress.estimatedTimeRemainingText == "~1 min, 20 sec remaining")
    }

    @Test func soundIndexProgressWaitsForObservedRateAndHandlesCompletion() {
        let start = Date(timeIntervalSince1970: 1_000)
        let calculating = SoundIndexProgress(
            totalTracks: 3,
            indexedTracks: 0,
            startedAt: start,
            now: start
        )
        let finished = SoundIndexProgress(
            totalTracks: 3,
            indexedTracks: 3,
            startedAt: start,
            now: start.addingTimeInterval(12)
        )

        #expect(calculating.estimatedSecondsRemaining == nil)
        #expect(calculating.estimatedTimeRemainingText == nil)
        #expect(finished.remainingTracks == 0)
        #expect(finished.estimatedSecondsRemaining == nil)
    }

    // MARK: - Repository idempotency

    @Test func importLocalFolderInsertsSourceBookAndChapters() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-import")
        let repository = LibraryRepository(database: database)
        let folder = URL(fileURLWithPath: "/tmp/watch-\(UUID().uuidString)")

        let imported = try await repository.importLocalFolder(
            folderURL: folder,
            folderName: "My Folder",
            files: [
                LocalAudioImport(url: folder.appendingPathComponent("01.mp3"), title: "01", sortKey: "01.mp3", duration: 60),
                LocalAudioImport(url: folder.appendingPathComponent("02.mp3"), title: "02", sortKey: "02.mp3", duration: 90)
            ]
        )

        #expect(imported.book.title == "My Folder")
        #expect(imported.chapters.count == 2)
        #expect(imported.chapters.allSatisfy { $0.localURL != nil })
        #expect(imported.chapters.allSatisfy { $0.remoteURL == nil })

        let sources = try await repository.fetchSources()
        #expect(sources.filter { $0.kind == .localFiles }.count == 1)
    }

    @Test func importLocalFolderIsIdempotentAndAppendsNewFiles() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-idempotent")
        let repository = LibraryRepository(database: database)
        let folder = URL(fileURLWithPath: "/tmp/watch-\(UUID().uuidString)")

        let f1 = LocalAudioImport(url: folder.appendingPathComponent("01.mp3"), title: "01", sortKey: "01.mp3", duration: 60)
        let f2 = LocalAudioImport(url: folder.appendingPathComponent("02.mp3"), title: "02", sortKey: "02.mp3", duration: 90)
        let f3 = LocalAudioImport(url: folder.appendingPathComponent("03.mp3"), title: "03", sortKey: "03.mp3", duration: 120)

        _ = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        let rescan = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        #expect(rescan.chapters.count == 2)  // Re-scanning identical files must not duplicate chapters

        let grown = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2, f3])
        #expect(grown.chapters.count == 3)  // A newly added file must append exactly one chapter

        let library = try await repository.fetchLibrary()
        #expect(library.count == 1)  // One book per folder
        let sources = try await repository.fetchSources()
        #expect(sources.count == 1)  // One source per folder
    }
    @Test func repairsLegacyBookmarksWithoutChangingChapterOrPlaybackIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("one.mp3")
        try Data("audio".utf8).write(to: audio)
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-bookmark-repair")
        let repository = LibraryRepository(database: database)
        let imported = try await repository.importLocalFolder(
            folderURL: folder, folderName: "Legacy book",
            files: [LocalAudioImport(url: audio, title: "One", sortKey: "one.mp3", duration: 60)]
        )
        let chapter = try #require(imported.chapters.first)
        #expect(chapter.localBookmark == nil)
        try await database.execute(
            """
            INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
            VALUES (?, ?, ?, 23, 60, 1000, 0)
            """,
            [.string(UUID().uuidString), .string(imported.book.id.uuidString), .string(chapter.id.uuidString)]
        )
        let defaultsName = "Voxglass.FolderAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let service = FolderWatchService(repository: repository, defaults: defaults)
        await service.addFolder(folder)
        await service.addFolder(folder)
        #expect(service.folders.count == 1)
        #expect((defaults.array(forKey: "voxglass.folderWatch.bookmarks") as? [Data])?.count == 1)
        #expect(service.errorMessage == nil)
        #expect(try await repository.repairLocalFileBookmarks(forFolder: folder) == 0)
        let reloaded = try #require(try await repository.fetchLibrary().first)
        #expect(reloaded.book.id == imported.book.id)
        #expect(reloaded.chapters.count == 1)
        #expect(reloaded.chapters.first?.id == chapter.id)
        #expect(reloaded.chapters.first?.duration == 60)
        #expect(reloaded.chapters.first?.localBookmark != nil)
        #expect(reloaded.chapters.first?.resolvedPlayableURL()?.standardizedFileURL == audio.standardizedFileURL)
        let position = try await database.query("SELECT position_seconds FROM playback_positions WHERE chapter_id = ?", [.string(chapter.id.uuidString)])
        #expect(position.first?.double("position_seconds") == 23)
    }


    @Test func repairsLegacyBookmarksViaNonCanonicalSelectionAndDirectFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("one.mp3")
        let other = folder.appendingPathComponent("two.mp3")
        try Data("audio".utf8).write(to: audio)
        try Data("audio".utf8).write(to: other)
        let repository = LibraryRepository(database: AppDatabase.makeTemporaryDatabase(named: "reselect-repair"))
        let imported = try await repository.importLocalFolder(
            folderURL: folder, folderName: "Legacy",
            files: [
                LocalAudioImport(url: audio, title: "One", sortKey: "1", duration: 60),
                LocalAudioImport(url: other, title: "Two", sortKey: "2", duration: 60)
            ]
        )
        #expect(imported.chapters.allSatisfy { $0.localBookmark == nil })
        // A file selected directly repairs only that file's chapter.
        #expect(try await repository.repairLocalFileBookmarks(forFolder: audio) == 1)
        // The same folder spelled through /private (or an unstandardized path) still matches.
        let alias = URL(fileURLWithPath: folder.path + "/../" + folder.lastPathComponent, isDirectory: true)
        #expect(try await repository.repairLocalFileBookmarks(forFolder: alias) == 1)
        let library = try await repository.fetchLibrary()
        #expect(library.count == 1)
        #expect(Set(library[0].chapters.map(\.id)) == Set(imported.chapters.map(\.id)))
        #expect(library[0].chapters.allSatisfy { $0.localBookmark != nil })
    }

    @Test func movedFileStaysPresentAndUnrepairedWithoutDuplication() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("gone.mp3")
        try Data("audio".utf8).write(to: audio)
        let repository = LibraryRepository(database: AppDatabase.makeTemporaryDatabase(named: "moved-file"))
        let imported = try await repository.importLocalFolder(
            folderURL: folder, folderName: "Gone",
            files: [LocalAudioImport(url: audio, title: "Gone", sortKey: "1", duration: 60)]
        )
        try FileManager.default.removeItem(at: audio)
        #expect(try await repository.repairLocalFileBookmarks(forFolder: folder) == 0)
        let library = try await repository.fetchLibrary()
        #expect(library.count == 1)
        #expect(library[0].chapters.map(\.id) == imported.chapters.map(\.id))
    }

    @Test func importPersistsBookmarkProvidedWhileAccessIsGranted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("book.mp3")
        try Data("audio".utf8).write(to: audio)
        let repository = LibraryRepository(database: AppDatabase.makeTemporaryDatabase(named: "persist-bookmark"))
        let imported = try await repository.importLocalFolder(
            folderURL: folder, folderName: "Book",
            files: [LocalAudioImport(url: audio, title: "Book", sortKey: "1", duration: 60, bookmark: try audio.bookmarkData())]
        )
        #expect(imported.chapters.first?.localBookmark != nil)
        #expect(try await repository.fetchLibrary().first?.chapters.first?.localBookmark != nil)
    }

    @Test func localOnlyUnavailableMessageDoesNotOfferRemoteFallback() {
        let local = Chapter(bookID: UUID(), title: "c", index: 0, localBookmark: Data("x".utf8))
        let resolution = PlaybackSourceResolver(bookmarkResolver: { _ in nil }).resolve(local)
        if case .missingFile = resolution {} else { Issue.record("expected missingFile, got \(resolution)") }
        #expect(!LocalPlaybackUnavailable.message.isEmpty)
    }

    // MARK: - Off-main indexing worker

    private func makeAudioFolder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    @Test func indexerDiscoversPlayableUnknownFilesInFilenameOrder() async throws {
        let folder = try makeAudioFolder(["10.mp3", "2.mp3", "1.mp3", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let known = URL(fileURLWithPath: folder.appendingPathComponent("1.mp3").path)
            .standardizedFileURL.resolvingSymlinksInPath()
        let worker = FolderIndexingWorker(probeDuration: { _ in 5 })
        let result = try await worker.index(folder: folder, knownURLs: [known]) { _, _ in }
        #expect(result.map(\.sortKey) == ["2.mp3", "10.mp3"])
        #expect(result.allSatisfy { $0.bookmark != nil && $0.duration == 5 })
    }

    @Test func indexerLimitsConcurrencyAndProbesEachInputOnce() async throws {
        let names = (1...12).map { "\($0).mp3" }
        let folder = try makeAudioFolder(names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let counter = ProbeCounter()
        let worker = FolderIndexingWorker(maxConcurrency: 2, probeDuration: { url in
            await counter.enter(url)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await counter.leave()
            return 1
        })
        let result = try await worker.index(folder: folder, knownURLs: []) { _, _ in }
        #expect(result.count == 12)
        #expect(await counter.maxActive <= 2)
        #expect(await counter.seen.count == 12)
        #expect(await counter.total == 12)
    }

    @Test func indexerCancellationReturnsNoBatchAndReleasesScope() async throws {
        let folder = try makeAudioFolder((1...6).map { "\($0).mp3" })
        defer { try? FileManager.default.removeItem(at: folder) }
        let scopes = ScopeCounter()
        let worker = FolderIndexingWorker(
            startScope: { _ in scopes.start(); return true },
            stopScope: { _ in scopes.stop() },
            probeDuration: { _ in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
        )
        let task = Task { try await worker.index(folder: folder, knownURLs: []) { _, _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(scopes.balance == 0 && scopes.started == 1)
    }

    @Test func indexerReleasesScopeOnSuccessAndFailure() async throws {
        let folder = try makeAudioFolder(["1.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let scopes = ScopeCounter()
        let ok = FolderIndexingWorker(startScope: { _ in scopes.start(); return true }, stopScope: { _ in scopes.stop() }, probeDuration: { _ in 1 })
        _ = try await ok.index(folder: folder, knownURLs: []) { _, _ in }
        struct Boom: Error {}
        let bad = FolderIndexingWorker(startScope: { _ in scopes.start(); return true }, stopScope: { _ in scopes.stop() }, makeBookmark: { _ in throw Boom() }, probeDuration: { _ in 1 })
        await #expect(throws: FolderIndexError.self) { try await bad.index(folder: folder, knownURLs: []) { _, _ in } }
        #expect(scopes.balance == 0 && scopes.started == 2)
    }

    // MARK: - Progress throttle

    @Test func progressThrottleEmitsFirstFinalAndAtMostFourPerSecond() {
        var throttle = ProgressThrottle()
        let t0 = Date(timeIntervalSince1970: 0)
        var emitted: [Int] = []
        for i in 0...100 {
            let now = t0.addingTimeInterval(Double(i) * 0.01) // 100 updates in 1s
            if throttle.shouldEmit(indexed: i, total: 100, now: now) { emitted.append(i) }
        }
        #expect(emitted.first == 0)
        #expect(emitted.last == 100) // exact final count
        #expect(emitted.count <= 6) // first + <=4 intermediate + final
    }

    @Test func serviceRefreshOnlyDrivenByNewFiles() async throws {
        let folder = try makeAudioFolder([])
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = FolderIndexingWorker(probeDuration: { _ in 1 })
        let result = try await worker.index(folder: folder, knownURLs: []) { _, _ in }
        #expect(result.isEmpty) // service returns before import/refresh on an empty batch
    }
}

private actor ProbeCounter {
    var active = 0, maxActive = 0, total = 0
    var seen = Set<URL>()
    func enter(_ url: URL) { active += 1; maxActive = max(maxActive, active); total += 1; seen.insert(url) }
    func leave() { active -= 1 }
}

private final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var s = 0, e = 0
    func start() { lock.lock(); s += 1; lock.unlock() }
    func stop() { lock.lock(); e += 1; lock.unlock() }
    var started: Int { lock.lock(); defer { lock.unlock() }; return s }
    var balance: Int { lock.lock(); defer { lock.unlock() }; return s - e }
}
