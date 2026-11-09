import AVFoundation
import Foundation
import Testing
@testable import VoxglassCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class MemoryCache: ReadWithAIWatchNarrationCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: URL] = [:]
    func cachedOutput(for key: String) -> URL? { lock.lock(); defer { lock.unlock() }; return map[key] }
    func store(_ output: URL, for key: String) { lock.lock(); map[key] = output; lock.unlock() }
}

@MainActor
private final class FakeRenderer: ReadWithAIWatchSpeechRendering {
    var calls = 0
    var sawMainThread = false
    var delay: Duration?
    let pcm: URL
    init(pcm: URL) { self.pcm = pcm }
    func renderPCM(textURL: URL, preference: ReadWithAIVoicePreference) async throws -> URL {
        calls += 1
        sawMainThread = onMain()
        if let delay { try await Task.sleep(for: delay) }
        try Data("pcm".utf8).write(to: pcm)
        return pcm
    }
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("rwai-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func workerDeps(log: Log = Log(), failHE: Bool = false) -> WatchAudioPreparationWorker.Dependencies {
    .init(
        hash: { _ in log.add("hash:main=\(onMain())"); return String(repeating: "a", count: 64) },
        prepareAAC: { _, d, _ in d },
        fileInfo: { _ in log.add("info:main=\(onMain())"); return (4, String(repeating: "b", count: 64), 7) },
        artwork: { _ in nil },
        convertPCM: { _, dir, _, rate, format in
            log.add("convert:\(rate):main=\(onMain())")
            if failHE && format == kAudioFormatMPEG4AAC_HE { struct E: Error {}; throw E() }
            let out = dir.appendingPathComponent("out-\(rate).m4a")
            try Data("aac".utf8).write(to: out)
            return out
        })
}

private func textFile(_ dir: URL) throws -> URL {
    let t = dir.appendingPathComponent("c.voxtext")
    try Data("hello".utf8).write(to: t)
    return t
}

@Suite struct ReadWithAIWatchPreparationAdapterTests {
    private let pref = ReadWithAIVoicePreference(identifier: "")

    @Test @MainActor func speechRendererIsInvokedOnMainActor() async throws {
        let dir = tempDir()
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        _ = try await adapter.prepareNarration(textURL: try textFile(dir), preference: pref, renderer: renderer,
            cache: MemoryCache(), worker: WatchAudioPreparationWorker(dependencies: workerDeps()))
        #expect(renderer.sawMainThread)
    }

    @Test @MainActor func pcmConversionAndHashingRunOutsideMainActor() async throws {
        let dir = tempDir(); let log = Log()
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        _ = try await adapter.prepareNarration(textURL: try textFile(dir), preference: pref, renderer: renderer,
            cache: MemoryCache(), worker: WatchAudioPreparationWorker(dependencies: workerDeps(log: log)))
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0.hasSuffix("main=false") })
    }

    @Test func heaacFailureFallsBackToAacLC() async throws {
        let dir = tempDir(); let log = Log()
        let pcm = dir.appendingPathComponent("s.caf"); try Data("pcm".utf8).write(to: pcm)
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareRenderedPCM(
            pcm, worker: WatchAudioPreparationWorker(dependencies: workerDeps(log: log, failHE: true)))
        let converts = log.all.filter { $0.hasPrefix("convert") }
        #expect(converts.count == 2)
        #expect(converts[0].hasPrefix("convert:\(WatchNarrationEstimate.preferredBitRate)"))
        #expect(converts[1].hasPrefix("convert:48000"))
        #expect(chapter.duration == 7 && chapter.bytes == 4)
    }

    @Test @MainActor func cancellationStopsSpeechAndLeavesNoPartialManifest() async throws {
        let dir = tempDir(); let log = Log()
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        renderer.delay = .seconds(30)
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let text = try textFile(dir)
        let worker = WatchAudioPreparationWorker(dependencies: workerDeps(log: log))
        let task = Task { try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
            cache: MemoryCache(), worker: worker) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.all.filter { $0.hasPrefix("convert") }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s.caf").path))
    }

    @Test @MainActor func completedChapterUsesWorkerBoundaryAndTemporaryPCMIsRemoved() async throws {
        let dir = tempDir()
        let pcm = dir.appendingPathComponent("s.caf")
        let id = UUID()
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: id, chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareNarration(textURL: try textFile(dir), preference: pref,
            renderer: FakeRenderer(pcm: pcm), cache: MemoryCache(),
            worker: WatchAudioPreparationWorker(dependencies: workerDeps()))
        #expect(chapter.chapterID == id && chapter.chapterKey == "k")
        #expect(chapter.sha256 == String(repeating: "b", count: 64))
        #expect(!FileManager.default.fileExists(atPath: pcm.path))
    }

    @Test @MainActor func mixedChaptersKeepOrderedManifest() async throws {
        let dir = tempDir()
        let worker = WatchAudioPreparationWorker(dependencies: workerDeps())
        let cache = MemoryCache()
        let text = try textFile(dir)
        var ids: [UUID] = []
        var results: [PreparedWatchChapter] = []
        for i in 0..<3 {
            let id = UUID(); ids.append(id)
            let adapter = ReadWithAIWatchPreparationAdapter(chapterID: id, chapterKey: "k\(i)", directory: dir)
            results.append(try await adapter.prepareNarration(textURL: text, preference: pref,
                renderer: FakeRenderer(pcm: dir.appendingPathComponent("s\(i).caf")), cache: cache, worker: worker))
        }
        #expect(results.map(\.chapterID) == ids)
    }

    @Test @MainActor func cachedNarrationOutputAvoidsRepeatingSpeech() async throws {
        let dir = tempDir()
        let cache = MemoryCache()
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let worker = WatchAudioPreparationWorker(dependencies: workerDeps())
        let text = try textFile(dir)
        for _ in 0..<2 {
            let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
            _ = try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
                                                   cache: cache, worker: worker)
        }
        #expect(renderer.calls == 1)
    }
}

private func onMain() -> Bool { Thread.isMainThread }
