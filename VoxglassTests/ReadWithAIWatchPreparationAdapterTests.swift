import AVFoundation
import Foundation
import Testing
@testable import VoxglassCore
import VoxglassWatchCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class MemoryCache: ReadWithAIWatchNarrationCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: URL] = [:]
    func validCachedOutput(for key: String) -> URL? { lock.lock(); defer { lock.unlock() }; return map[key] }
    func storeValidated(_ output: URL, for key: String) { lock.lock(); map[key] = output; storedKeys.append(key); lock.unlock() }
    func removeOutput(for key: String) { lock.lock(); map[key] = nil; lock.unlock() }
    func purgeLegacyEntries() throws {}
    private(set) var storedKeys: [String] = []
}

/// Real AAC-LC M4A produced by AVFoundation.
func writeRealAAC(to url: URL) throws {
    let pcm = url.deletingPathExtension().appendingPathExtension("tmp-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: pcm) }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
    buf.frameLength = 44_100
    for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
    do { let f = try AVAudioFile(forWriting: pcm, settings: fmt.settings); try f.write(from: buf) }
    do {
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        try out.write(from: buf)
    }
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

private func workerDeps(log: Log = Log()) -> WatchAudioPreparationWorker.Dependencies {
    .init(
        hash: { _ in log.add("hash:main=\(onMain())"); return String(repeating: "a", count: 64) },
        prepareAAC: { _, d, _ in d },
        fileInfo: { _ in log.add("info:main=\(onMain())"); return (4, String(repeating: "b", count: 64), 7) },
        artwork: { _ in nil },
        convertPCM: { _, dir, _, rate, format in
            log.add("convert:\(rate):\(format):main=\(onMain())")
            let out = dir.appendingPathComponent("out-\(rate).m4a")
            try writeRealAAC(to: out)
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

    @Test func narrationUsesOnlyAacLCAt48kbps() async throws {
        let dir = tempDir(); let log = Log()
        let pcm = dir.appendingPathComponent("s.caf"); try Data("pcm".utf8).write(to: pcm)
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareRenderedPCM(
            pcm, worker: WatchAudioPreparationWorker(dependencies: workerDeps(log: log)))
        let converts = log.all.filter { $0.hasPrefix("convert") }
        #expect(converts == ["convert:48000:\(kAudioFormatMPEG4AAC):main=false"])
        #expect(chapter.duration == 7 && chapter.bytes == 4)
    }

    @Test func narrationByteEstimateUsesFixedAacLCProfile() {
        #expect(WatchNarrationEstimate.estimatedAudioBytes(duration: 10) == 60_000)
    }

    @Test func liveConversionProducesRealAacLCM4A() async throws {
        let dir = tempDir()
        let pcm = dir.appendingPathComponent("tone.caf")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
        buf.frameLength = 44_100
        for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
        do { let f = try AVAudioFile(forWriting: pcm, settings: fmt.settings); try f.write(from: buf) }
        let hash = String(repeating: "c", count: 64)
        let output = try await WatchAudioPreparationWorker.Dependencies.liveConvertPCM(
            pcm, dir, hash, WatchNarrationEstimate.watchAACLCBitRate, kAudioFormatMPEG4AAC)
        let audio = try AVAudioFile(forReading: output)
        #expect(audio.length > 0)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(output.pathExtension.lowercased() == "m4a")
        #expect(output.lastPathComponent.contains("watch-aac48"))
        #expect(!output.lastPathComponent.contains("heaac"))
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

    @Test @MainActor func invalidGeneratedNarrationIsNotCached() async throws {
        let dir = tempDir(); let cache = MemoryCache()
        var deps = workerDeps()
        deps.convertPCM = { _, d, _, _, _ in
            let out = d.appendingPathComponent("bad.m4a"); try Data("aac".utf8).write(to: out); return out
        }
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let text = try textFile(dir)
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        await #expect(throws: WatchAACAssetValidationError.self) {
            _ = try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
                cache: cache, worker: WatchAudioPreparationWorker(dependencies: deps))
        }
        #expect(cache.storedKeys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.m4a").path))
    }

    private func isolatedCache(root: URL) -> (ReadWithAIWatchNarrationUserDefaultsCache, UserDefaults) {
        let name = "rwai-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (ReadWithAIWatchNarrationUserDefaultsCache(suiteName: name, managedRoot: root), d)
    }

    @Test @MainActor func legacyEntryIsPurgedAndForcesFreshAacLCGeneration() async throws {
        let dir = tempDir(); let outside = tempDir()
        let (cache, defaults) = isolatedCache(root: dir)
        let text = try textFile(dir)
        let legacyInside = dir.appendingPathComponent("legacy.m4a"); try writeRealAAC(to: legacyInside)
        let legacyOutside = outside.appendingPathComponent("keep.m4a"); try writeRealAAC(to: legacyOutside)
        let old = ReadWithAIWatchNarrationUserDefaultsCache.legacyPrefix
        defaults.set(legacyInside.path, forKey: old + "a")
        defaults.set(legacyOutside.path, forKey: old + "b")
        let key = try ReadWithAIWatchPreparationAdapter.cacheKey(textURL: text, preference: pref)
        defaults.set(legacyInside.path, forKey: old + key)
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
            cache: cache, worker: WatchAudioPreparationWorker(dependencies: workerDeps()))
        #expect(renderer.calls == 1)
        #expect(chapter.url != legacyInside)
        #expect(!FileManager.default.fileExists(atPath: legacyInside.path))
        #expect(FileManager.default.fileExists(atPath: legacyOutside.path))
        #expect(defaults.string(forKey: old + "a") == nil && defaults.string(forKey: old + "b") == nil)
        #expect(defaults.string(forKey: old + key) == nil)
        #expect(defaults.string(forKey: ReadWithAIWatchNarrationUserDefaultsCache.prefix + key) != nil)
    }

    @Test func cacheKeyChangesWhenProfileChanges() throws {
        let dir = tempDir(); let text = try textFile(dir)
        let k1 = try ReadWithAIWatchPreparationAdapter.cacheKey(textURL: text, preference: pref)
        let expected = SHA256Hex.hex(Data("aaclc48-v1|\(try WatchChecksum.sha256(of: text))|automatic|44100|2|48000".utf8))
        #expect(k1 == expected)
        let k2 = try ReadWithAIWatchPreparationAdapter.cacheKey(
            textURL: text, preference: ReadWithAIVoicePreference(identifier: "voice.x"))
        #expect(k1 != k2)
        #expect(ReadWithAIWatchNarrationUserDefaultsCache.prefix == "readWithAI.watchNarration.aaclc48.v1.")
    }

    @Test @MainActor func corruptCachedM4AIsDeletedAndRegenerated() async throws {
        let dir = tempDir()
        let (cache, defaults) = isolatedCache(root: dir)
        let text = try textFile(dir)
        let key = try ReadWithAIWatchPreparationAdapter.cacheKey(textURL: text, preference: pref)
        let corrupt = dir.appendingPathComponent("corrupt.m4a")
        try Data("aac".utf8).write(to: corrupt)
        defaults.set(corrupt.path, forKey: ReadWithAIWatchNarrationUserDefaultsCache.prefix + key)
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
            cache: cache, worker: WatchAudioPreparationWorker(dependencies: workerDeps()))
        #expect(renderer.calls == 1)
        #expect(chapter.url != corrupt)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        try WatchAACAssetValidator.validate(chapter.url)
    }

    @Test func cacheRefusingOutsideManagedRootNeverDeletesThatExternalFile() throws {
        let dir = tempDir(); let outside = tempDir()
        let (cache, defaults) = isolatedCache(root: dir)
        let external = outside.appendingPathComponent("ext.m4a"); try writeRealAAC(to: external)
        let wrongExt = dir.appendingPathComponent("x.mp3"); try Data("x".utf8).write(to: wrongExt)
        let p = ReadWithAIWatchNarrationUserDefaultsCache.prefix
        defaults.set(external.path, forKey: p + "ext")
        defaults.set(wrongExt.path, forKey: p + "ext2")
        defaults.set(dir.appendingPathComponent("missing.m4a").path, forKey: p + "missing")
        #expect(cache.validCachedOutput(for: "ext") == nil)
        #expect(cache.validCachedOutput(for: "ext2") == nil)
        #expect(cache.validCachedOutput(for: "missing") == nil)
        #expect(FileManager.default.fileExists(atPath: external.path))
        #expect(defaults.string(forKey: p + "ext") == nil)
        #expect(defaults.string(forKey: p + "ext2") == nil)
        #expect(defaults.string(forKey: p + "missing") == nil)
        cache.storeValidated(external, for: "again")
        #expect(defaults.string(forKey: p + "again") == nil)
    }

    @Test @MainActor func validAacLCEntryIsReusedWithoutSpeechRendering() async throws {
        let dir = tempDir()
        let (cache, _) = isolatedCache(root: dir)
        let text = try textFile(dir)
        let key = try ReadWithAIWatchPreparationAdapter.cacheKey(textURL: text, preference: pref)
        let good = dir.appendingPathComponent("good.m4a"); try writeRealAAC(to: good)
        cache.storeValidated(good, for: key)
        let renderer = FakeRenderer(pcm: dir.appendingPathComponent("s.caf"))
        let adapter = ReadWithAIWatchPreparationAdapter(chapterID: UUID(), chapterKey: "k", directory: dir)
        let chapter = try await adapter.prepareNarration(textURL: text, preference: pref, renderer: renderer,
            cache: cache, worker: WatchAudioPreparationWorker(dependencies: workerDeps()))
        #expect(renderer.calls == 0)
        #expect(chapter.url.lastPathComponent == "good.m4a")
        #expect(FileManager.default.fileExists(atPath: good.path))
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
