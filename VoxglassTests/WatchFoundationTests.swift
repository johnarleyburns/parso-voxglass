import Foundation
import Testing
@testable import VoxglassWatchProtocol
@testable import VoxglassWatchCore

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
}
