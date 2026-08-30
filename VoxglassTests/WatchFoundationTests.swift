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
}
