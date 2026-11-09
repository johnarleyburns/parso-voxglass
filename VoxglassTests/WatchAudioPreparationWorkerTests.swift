import Foundation
import Testing
import VoxglassWatchProtocol
@testable import VoxglassCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func bump(_ key: String) { lock.lock(); values[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
}

private struct Boom: Error {}

private func makeDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voxglass-worker-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func input(directory: URL, sources: [URL]) -> OrdinaryWatchPreparationInput {
    OrdinaryWatchPreparationInput(
        bookID: UUID(),
        chapters: sources.enumerated().map { index, source in
            OrdinaryWatchChapterInput(chapterID: UUID(), chapterKey: "k\(index)", index: index,
                title: "Chapter \(index)", source: source, startTime: Double(index) * 10,
                duration: 10, mimeType: nil)
        },
        directory: directory)
}

private func deps(
    counter: Counter = Counter(),
    failAt: Int? = nil,
    artwork: PreparedWatchArtwork? = nil,
    onPrepare: @escaping @Sendable (OrdinaryWatchChapterInput, URL) throws -> Void = { _, _ in }
) -> WatchAudioPreparationWorker.Dependencies {
    .init(
        hash: { url in counter.bump("hash"); return String(repeating: "a", count: 64) },
        prepareAAC: { chapter, directory, _ in
            counter.bump("prepare")
            if chapter.index == failAt { throw Boom() }
            try onPrepare(chapter, directory)
            let out = directory.appendingPathComponent("\(chapter.chapterID).m4a")
            try Data("aac".utf8).write(to: out)
            return out
        },
        fileInfo: { _ in (3, String(repeating: "b", count: 64), 10) },
        artwork: { _ in artwork })
}

@Suite struct WatchAudioPreparationWorkerTests {
    @Test func workerBuildsCompleteOrderedManifestForOrdinaryAudio() async throws {
        let dir = makeDirectory()
        let sources = (0..<3).map { URL(fileURLWithPath: "/tmp/src\($0).mp3") }
        let request = input(directory: dir, sources: sources)
        let result = try await WatchAudioPreparationWorker(dependencies: deps()).prepare(request) { _ in }
        #expect(result.chapters.map(\.index) == [0, 1, 2])
        #expect(result.files.map(\.chapterID) == request.chapters.map(\.chapterID))
        #expect(result.chapters.allSatisfy { $0.expectedBytes == 3 && $0.expectedSHA256 != nil })
        #expect(result.chapters.map(\.durableFilename) == request.chapters.map { "\($0.chapterID.uuidString).m4a" })
    }

    @Test func sharedSourceHashOccursOnce() async throws {
        let counter = Counter()
        let shared = URL(fileURLWithPath: "/tmp/book.m4b")
        _ = try await WatchAudioPreparationWorker(dependencies: deps(counter: counter))
            .prepare(input(directory: makeDirectory(), sources: [shared, shared, shared])) { _ in }
        #expect(counter.count("hash") == 1)
        #expect(counter.count("prepare") == 3)
    }

    @Test func workerResultHasNoPhoneAudioRelayOrWCSessionReference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Voxglass/Core/Services/Watch/WatchAudioPreparationWorker.swift"), encoding: .utf8)
        #expect(!text.contains("PhoneAudioRelay"))
        #expect(!text.contains("WCSession"))
        #expect(!text.contains("@MainActor"))
    }

    @Test func failureDoesNotProducePartialManifest() async {
        let dir = makeDirectory()
        let worker = WatchAudioPreparationWorker(dependencies: deps(failAt: 2))
        await #expect(throws: Boom.self) {
            _ = try await worker.prepare(input(directory: dir, sources: (0..<3).map { URL(fileURLWithPath: "/tmp/s\($0)") })) { _ in }
        }
    }

    @Test func staleResultIsDiscardedBeforeMainActorCommit() {
        var generations = WatchPreparationGenerations()
        let book = UUID()
        let first = generations.begin(book)
        let second = generations.begin(book)
        #expect(!generations.isCurrent(first, for: book))
        #expect(generations.isCurrent(second, for: book))
    }

    @Test func cancellationRemovesOnlyDisposableDerivedFiles() async throws {
        let dir = makeDirectory()
        let original = dir.appendingPathComponent("original.mp3")
        let cached = dir.appendingPathComponent("cached.m4a")
        try Data("o".utf8).write(to: original)
        try Data("c".utf8).write(to: cached)
        let worker = WatchAudioPreparationWorker(dependencies: deps(onPrepare: { chapter, directory in
            if chapter.index == 1 {
                try Data("x".utf8).write(to: directory.appendingPathComponent("tmp.m4a.preparing"))
                throw CancellationError()
            }
        }))
        await #expect(throws: CancellationError.self) {
            _ = try await worker.prepare(input(directory: dir, sources: [original, original])) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tmp.m4a.preparing").path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: cached.path))
    }

    @Test func artworkFailureKeepsPreparedAudioValid() async throws {
        let result = try await WatchAudioPreparationWorker(dependencies: deps(artwork: nil))
            .prepare(input(directory: makeDirectory(), sources: [URL(fileURLWithPath: "/tmp/a")])) { _ in }
        #expect(result.artwork == nil)
        #expect(result.chapters.count == 1)
    }

    @Test func projectionAndTransfersAreCommittedOnlyAfterCompleteResult() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Voxglass/App/PhoneAudioRelay.swift"), encoding: .utf8)
        let prepare = try #require(text.range(of: "try await worker.prepare("))
        let generation = try #require(text.range(of: "isCurrent(generation", range: prepare.upperBound..<text.endIndex))
        let select = try #require(text.range(of: "try await watchProjectionStore.select(selected)", range: generation.upperBound..<text.endIndex))
        let transfer = try #require(text.range(of: "transferChapterFile(", range: select.upperBound..<text.endIndex))
        #expect(prepare.lowerBound < generation.lowerBound)
        #expect(generation.lowerBound < select.lowerBound)
        #expect(select.lowerBound < transfer.lowerBound)
    }
}
