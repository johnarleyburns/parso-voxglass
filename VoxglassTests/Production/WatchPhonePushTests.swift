import AVFoundation
import Foundation
import Testing
@testable import VoxglassCore
import VoxglassWatchCore
import VoxglassWatchProtocol

@Suite("Phone-only AAC96 watch listening")
struct WatchPhonePushTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUIDGenerator().next().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "cc0-ocean-watch", withExtension: "mp3", subdirectory: "ReplayGain"))
    }

    private func validateAAC(_ url: URL) throws {
        let audio = try AVAudioFile(forReading: url)
        guard audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              audio.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    @Test("A real extensionless CC0 MP3 becomes readable AAC96 without touching its original")
    func actualAAC() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("extensionless-cache-blob")
        try FileManager.default.copyItem(at: fixture(), to: source)
        let originalHash = try WatchChecksum.sha256(of: source)
        let url = try await WatchChapterTransfer.prepareAAC(source: source, directory: root.appendingPathComponent("aac"), mimeType: "audio/mpeg")
        let audio = try AVAudioFile(forReading: url)
        #expect(WatchChapterTransfer.watchBitRate == 96_000)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(audio.length > 0)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096))
        try audio.read(into: pcm)
        #expect(pcm.frameLength > 0)
        #expect(try WatchChecksum.sha256(of: source) == originalHash)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }

    @Test("Shared-file audiobook chapters extract distinct zero-based clips")
    func chapterBounds() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        let first = try await WatchChapterTransfer.prepareAAC(source: source, directory: root, startTime: 0, duration: 0.25)
        let second = try await WatchChapterTransfer.prepareAAC(source: source, directory: root, startTime: 0.5, duration: 0.25)
        #expect(first != second)
        let duration = try await AVURLAsset(url: second).load(.duration).seconds
        #expect(duration > 0.2 && duration < 0.4)
    }

    @Test("Concurrent AAC conversions leave Swift workers available and all produce readable audio", .timeLimit(.minutes(1)))
    func concurrentAAC() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        try await withThrowingTaskGroup(of: URL.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await WatchChapterTransfer.prepareAAC(source: source,
                        directory: root.appendingPathComponent("conversion-\(index)"), mimeType: "audio/mpeg")
                }
            }
            var completed = 0
            for try await url in group {
                let audio = try AVAudioFile(forReading: url)
                #expect(audio.length > 0)
                #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
                completed += 1
            }
            #expect(completed == 12)
        }
    }

    @Test("Already-cancelled preparation does no file work")
    func cancelledAAC() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WatchChapterTransfer.prepareAAC(source: source, directory: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Files arriving before metadata, duplicates and relaunch derive installation from disk")
    func diskTruth() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await WatchChapterTransfer.prepareAAC(source: fixture(), directory: root.appendingPathComponent("aac"))
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let hash = try WatchChecksum.sha256(of: source)
        let audioRoot = root.appendingPathComponent("DownloadedBooks")
        for _ in 0..<2 {
            _ = try WatchPhonePushFiles.install(source: source, root: audioRoot, bookID: "book", filename: "one.m4a", expectedBytes: bytes, expectedSHA256: hash, validateAudio: validateAAC)
        }
        let one = WatchChapterDTO(id: "one", index: 0, title: "One", duration: 1, startTime: 0,
            expectedBytes: bytes, expectedSHA256: hash, durableFilename: "one.m4a")
        let two = WatchChapterDTO(id: "two", index: 1, title: "Two", duration: 1, startTime: 0,
            expectedBytes: bytes, expectedSHA256: hash, durableFilename: "two.m4a")
        let book = WatchBookDTO(id: "book", title: "Book", metadataRevision: 7, chapters: [one, two])
        let partial = WatchPhonePushFiles.report(book: book, root: audioRoot)
        #expect(!partial.complete && partial.installedChapterIDs == ["one"])
        #expect(partial.installedBytes == bytes)
        let installed = try WatchPhonePushFiles.install(source: source, root: audioRoot, bookID: "book", filename: "two.m4a", expectedBytes: bytes, expectedSHA256: hash, validateAudio: validateAAC)
        #expect(try AVAudioFile(forReading: installed).length > 0)
        let reopened = WatchPhonePushFiles.report(book: book, root: audioRoot)
        #expect(reopened.complete && reopened.installedChapterIDs?.count == 2)
        #expect(reopened.installedBytes == bytes * 2)
        try Data("corrupt".utf8).write(to: audioRoot.appendingPathComponent("book/two.m4a"))
        #expect(!WatchPhonePushFiles.report(book: book, root: audioRoot).complete)
    }

    @Test("An invalid delivery cannot replace verified audio or escape its directory")
    func invalidDelivery() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let hash = try WatchChecksum.sha256(of: source)
        let installed = try WatchPhonePushFiles.install(source: source, root: root, bookID: "book", filename: "one.m4a", expectedBytes: bytes, expectedSHA256: hash)
        #expect(throws: WatchDownloadPipelineError.checksumMismatch) {
            try WatchPhonePushFiles.install(source: source, root: root, bookID: "book", filename: "one.m4a", expectedBytes: bytes, expectedSHA256: "bad")
        }
        #expect(try WatchChecksum.sha256(of: installed) == hash)
        #expect(!WatchPhonePushFiles.safeComponent("../outside"))
        #expect(!WatchPhonePushFiles.safeComponent(".."))
    }

    @Test("Selected catalogs and incomplete reports persist without false installed state")
    func selectionAndReports() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = PhoneWatchProjectionStore(url: url, libraryID: "library")
        let book = WatchBookDTO(id: "selected", title: "Selected", metadataRevision: 4)
        try await store.select(book)
        try await store.setDesiredRoot(WatchManifest(bookID: book.id, revision: 4, requiredChapterIDs: ["one"]))
        try await store.acknowledge(WatchManifestAcknowledgement(bookID: book.id, revision: 3, complete: true, installedBytes: 100))
        #expect(!(await store.isTruthfullyDownloaded(book.id)))
        try await store.acknowledge(WatchManifestAcknowledgement(bookID: book.id, revision: 4, complete: false, installedBytes: 0))
        #expect(!(await store.isTruthfullyDownloaded(book.id)))
        let reopened = PhoneWatchProjectionStore(url: url, libraryID: "library")
        #expect(await reopened.current().selectedBooks == [book.id: book])
        try await reopened.remove(bookID: book.id)
        try await reopened.acknowledge(WatchManifestAcknowledgement(bookID: book.id, revision: 5, complete: false, installedBytes: 0))
        #expect(await reopened.current().selectedBooks.count == 1)
        var removal = WatchManifestAcknowledgement(bookID: book.id, revision: 5, complete: false, installedBytes: 0)
        removal.isRemoval = true
        try await reopened.acknowledge(removal)
        #expect(await reopened.current().selectedBooks.isEmpty)
        #expect(await reopened.current().desiredRoots.isEmpty)
        // An old completed removal cannot erase a new explicit user selection.
        try await reopened.select(book)
        try await reopened.setDesiredRoot(WatchManifest(bookID: book.id, revision: 8, requiredChapterIDs: ["one"]))
        try await reopened.acknowledge(removal)
        #expect(await reopened.current().selectedBooks[book.id] == book)
        try await reopened.remove(bookID: book.id, revision: 10)
        try await reopened.acknowledge(removal)
        #expect(await reopened.current().selectedBooks[book.id] == book)
    }

    @Test("An explicitly empty device report clears old installation claims without scheduling downloads")
    func emptyInventory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneWatchProjectionStore(url: root.appendingPathComponent("state.json"), libraryID: "library")
        let book = WatchBookDTO(id: "book", title: "Book", metadataRevision: 1)
        try await store.select(book)
        try await store.setDesiredRoot(WatchManifest(bookID: book.id, revision: 1, requiredChapterIDs: ["one"]))
        try await store.acknowledge(WatchManifestAcknowledgement(bookID: book.id, revision: 1, complete: true, installedBytes: 100))
        #expect(await store.isTruthfullyDownloaded(book.id))
        try await store.reconcile(WatchDeviceCatalog(reports: []))
        #expect(!(await store.isTruthfullyDownloaded(book.id)))
        #expect(await store.current().selectedBooks[book.id] == book)
        if case .failed = await store.current().desired[book.id] {} else { Issue.record("Reset must offer an explicit phone retry, not automatically start one") }
    }

    @Test("Compressed binary metadata round-trips without source URLs")
    func compressedCatalog() throws {
        let snapshot = WatchLibrarySnapshot(pairedLibraryID: "library", revision: 2,
            books: [WatchBookDTO(id: "book", title: "Selected book")])
        let data = try WatchProtocolEnvelope.encode(kind: .librarySnapshot, payload: snapshot, libraryID: "library")
        let wire = try PropertyListDecoder().decode(WatchProtocolEnvelope.self, from: data)
        #expect(wire.payloadCompression == "lzfse")
        #expect(try WatchProtocolEnvelope.decode(data).decodePayload(WatchLibrarySnapshot.self) == snapshot)
    }

    @Test("A pending transfer survives relaunch and only offers manual retry after 24 hours")
    func transferDeadline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = PhoneWatchProjectionStore(url: url, libraryID: "library")
        let start = Date(timeIntervalSince1970: 10_000)
        try await store.markSubmitted("pending", at: start)
        let reopened = PhoneWatchProjectionStore(url: url, libraryID: "library")
        try await reopened.expireTransfers(at: start.addingTimeInterval(86_399))
        #expect(await reopened.current().desired["pending"] == .transferring)
        try await reopened.expireTransfers(at: start.addingTimeInterval(86_400))
        if case .failed = await reopened.current().desired["pending"] {} else { Issue.record("Must offer manual retry after 24 hours") }
        try await reopened.acknowledge(WatchManifestAcknowledgement(bookID: "pending", revision: 1, complete: true, installedBytes: 20))
        try await reopened.expireTransfers(at: start.addingTimeInterval(172_800))
        #expect(await reopened.current().desired["pending"] == .downloaded)
    }

    @Test("A file labeled AAC is rejected if it is actually MP3")
    func rejectDisguisedMP3() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let hash = try WatchChecksum.sha256(of: source)
        #expect(throws: (any Error).self) {
            try WatchPhonePushFiles.install(source: source, root: root, bookID: "book", filename: "one.m4a",
                expectedBytes: bytes, expectedSHA256: hash, validateAudio: validateAAC)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("book/one.m4a").path))
    }

    @Test("Production watch has no network downloads, no hello, and no queued sync requests")
    func nativeBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let services = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/WatchAppServices.swift"), encoding: .utf8)
        #expect(!services.contains("URLSession"))
        #expect(!services.contains("requestDownload"))
        #expect(services.contains("allowsStreaming: false"))
        let adapter = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/WatchSessionAdapter.swift"), encoding: .utf8)
        #expect(!adapter.contains("kind: .hello"))
        #expect(!adapter.contains("kind: .setBookDownload"))
        #expect(adapter.contains("receivedApplicationContext"))
        #expect(adapter.contains("WCSession.default.isReachable else"))
        #expect(adapter.contains("WatchPhonePushFiles.install(source: file.fileURL"))
        let art = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/Kit/WatchProgressViews.swift"), encoding: .utf8)
        #expect(!art.contains("AsyncImage"))
    }

    @Test("Resume-only sync never rehashes whole audiobook files")
    func resumeMetadataIsCheap() {
        let old = WatchLibrarySnapshot(pairedLibraryID: "library", revision: 1,
            books: [WatchBookDTO(id: "book", title: "Book", chapters: [WatchChapterDTO(id: "one", index: 0, title: "One", duration: 100)])])
        var next = old
        next.revision = 2
        next.books[0].chapters[0].resumePosition = 50
        next.downloadStates = ["book": .downloaded]
        #expect(!WatchPhonePushFiles.needsReconciliation(previous: old, next: next))
        next.books[0].chapters[0].expectedSHA256 = "new content"
        #expect(WatchPhonePushFiles.needsReconciliation(previous: old, next: next))
    }
}
