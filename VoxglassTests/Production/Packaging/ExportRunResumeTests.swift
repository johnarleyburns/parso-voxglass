import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders
import VoxglassCoreTestSupport

/// P7 acceptance (spec §13.3): an export run is recorded chapter by chapter in
/// `ExportRunRecord`, an interruption leaves a resumable checkpoint, and a fresh
/// runner (simulating relaunch) resumes at the first incomplete chapter — the
/// finished chapters are reused, not re-encoded from zero.
@Suite struct ExportRunResumeTests {

    @Test func interruptedRunResumesAtFirstIncompleteChapter() async throws {
        let project = ProjectFixtures.librivoxReady() // 3 chapters
        let store = InMemoryProductionStore()
        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        // Run 1: the transcoder throws after chapter 1, simulating a force-quit
        // mid-run. The runner must persist chapter 1's checkpoint before the
        // interruption surfaces as a `.cancelled` run.
        let interrupting = InterruptingTranscoder(inner: VoxTranscoder(), failAfter: 1)
        let first = try await ResumableExportRunner(store: store).run(
            builder: LibriVoxPackageBuilder(),
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: interrupting,
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
            progress: { _ in }
        )
        #expect(first.run.status == .cancelled)
        #expect(first.run.fileHashes.count == 1, "run must persist the completed first chapter")

        let firstChapterName = Array(first.run.fileHashes.keys).first!
        let outputDir = exportsRoot
            .appendingPathComponent("LibriVox", isDirectory: true)
            .appendingPathComponent("ready-book", isDirectory: true)
        #expect(
            FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(firstChapterName).path),
            "the finished chapter's file must remain on disk for resume"
        )

        // Run 2: a fresh runner and a counting transcoder. Chapter 1 must be
        // reused (not re-encoded); chapters 2 and 3 are produced normally.
        let counting = CountingTranscoder(inner: VoxTranscoder())
        let second = try await ResumableExportRunner(store: store).run(
            builder: LibriVoxPackageBuilder(),
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: counting,
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
            progress: { _ in }
        )
        #expect(second.run.status == .succeeded)
        #expect(second.reusedFileCount == 1, "resume must reuse the finished first chapter")
        let chapters = second.bundle!.files.filter { $0.role == .chapter }
        #expect(chapters.count == 3)

        // The transcoder was never asked to re-encode the reused chapter, and
        // it encoded exactly the two remaining chapters.
        let encoded = await counting.encodedOutputs()
        #expect(!encoded.contains(firstChapterName))
        #expect(encoded.count == 2)

        // All three delivered files are real, verified 128 kbps CBR MP3s.
        for file in chapters {
            let data = try Data(contentsOf: file.url)
            #expect(MP3FrameParser.verifies(data: data, expectedKbps: 128, sampleRateHz: 44_100, mono: true))
        }
    }

    @Test func successfulRunIsNotReusedAsIncomplete() async throws {
        let project = ProjectFixtures.librivoxReady()
        let store = InMemoryProductionStore()
        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-done-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        // A fully successful run leaves a `.succeeded` row with all hashes.
        let first = try await ResumableExportRunner(store: store).run(
            builder: LibriVoxPackageBuilder(),
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
            progress: { _ in }
        )
        #expect(first.run.status == .succeeded)
        #expect(first.run.fileHashes.count == first.bundle!.files.count)

        // A re-export of the same project reuses every verified file (chapters
        // via the skip-unchanged pipeline; byte-identical artifacts match too).
        let second = try await ResumableExportRunner(store: store).run(
            builder: LibriVoxPackageBuilder(),
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
            progress: { _ in }
        )
        #expect(second.run.status == .succeeded)
        #expect(second.reusedFileCount == first.bundle!.files.count, "identical re-export reuses every verified file")
    }
}

// MARK: - Interruption seam

private actor TranscodeCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// Wraps a real transcoder and throws `CancellationError` once the number of
/// successful transcodes exceeds `failAfter`, simulating an interrupted run.
private struct InterruptingTranscoder: AudioTranscoding {
    let inner: any AudioTranscoding
    let failAfter: Int
    private let counter = TranscodeCounter()

    var availableEncoders: Set<Codec> { inner.availableEncoders }

    func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        let ordinal = await counter.next()
        if ordinal > failAfter { throw CancellationError() }
        return try await inner.transcode(input: input, to: spec, tags: tags, output: output, progress: progress)
    }

    func concatenate(_ inputs: [URL], to spec: AudioSpec, chapters: [ChapterMark]?, tags: AudioTags, output: URL) async throws -> ExportedFile {
        try await inner.concatenate(inputs, to: spec, chapters: chapters, tags: tags, output: output)
    }

    func master(input: URL, target: MasteringTarget, output: URL) async throws -> ExportedFile {
        try await inner.master(input: input, target: target, output: output)
    }
}

// MARK: - Recording seam

private actor OutputRecorder {
    private var outputs: Set<String> = []
    func add(_ name: String) { outputs.insert(name) }
    func snapshot() -> Set<String> { outputs }
}

/// Wraps a real transcoder and records every output filename it was asked to
/// encode, so a test can prove a resumed chapter was skipped.
private struct CountingTranscoder: AudioTranscoding {
    let inner: any AudioTranscoding
    private let recorder = OutputRecorder()

    var availableEncoders: Set<Codec> { inner.availableEncoders }

    func encodedOutputs() async -> Set<String> {
        await recorder.snapshot()
    }

    func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        await recorder.add(output.lastPathComponent)
        return try await inner.transcode(input: input, to: spec, tags: tags, output: output, progress: progress)
    }

    func concatenate(_ inputs: [URL], to spec: AudioSpec, chapters: [ChapterMark]?, tags: AudioTags, output: URL) async throws -> ExportedFile {
        try await inner.concatenate(inputs, to: spec, chapters: chapters, tags: tags, output: output)
    }

    func master(input: URL, target: MasteringTarget, output: URL) async throws -> ExportedFile {
        try await inner.master(input: input, target: target, output: output)
    }
}
