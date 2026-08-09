import Foundation

/// Drives a `PackageBuilder` with `ExportRunRecord` tracking so an export
/// survives backgrounding and relaunch (§13.3). The run is opened before any
/// file is written; each `.chapterFinished` progress event hashes the chapter's
/// primary output and persists it, so a force-quit mid-run leaves a resumable
/// checkpoint in the project's SQLite store.
///
/// A later run for the same destination and project detects the interrupted
/// run, re-verifies which recorded files still exist with matching content
/// hashes, and passes them to the builder as the skip-unchanged set — resume
/// restarts at the first incomplete chapter rather than from zero. Files whose
/// on-disk hash no longer matches (partial write) are simply re-produced.
public struct ResumableExportRunner {

    public struct Outcome: Sendable {
        /// The closed run row (`.succeeded`, `.cancelled`, or `.failed`).
        public let run: ExportRunRecord
        /// The produced package on success, nil otherwise.
        public let bundle: ExportBundle?
        /// How many already-finished files this run reused instead of re-encoding.
        public let reusedFileCount: Int

        public init(run: ExportRunRecord, bundle: ExportBundle?, reusedFileCount: Int) {
            self.run = run
            self.bundle = bundle
            self.reusedFileCount = reusedFileCount
        }
    }

    private let store: any ProductionStore
    private let clock: any Clock

    public init(store: any ProductionStore, clock: any Clock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    /// Runs `builder` for `project`, tracking progress in a new `ExportRunRecord`.
    ///
    /// - Throws: the builder's error (except `CancellationError`, which returns
    ///   an `Outcome` with a `.cancelled` run so the caller can show the resume
    ///   affordance and offer staging eviction).
    public func run(
        builder: any PackageBuilder,
        project: AudiobookProject,
        renders: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        assets: any ContentAddressedStore,
        into exportsRoot: URL,
        options: ExportOptions,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> Outcome {
        let outputDir = PackagingSupport.exportDirectory(for: builder.destination, project: project, exportsRoot: exportsRoot)

        // Resume detection happens before the new run is opened, so
        // `latestExportRun` still names the interrupted run (§13.3). Any of its
        // recorded files still on disk with matching content hashes become the
        // skip-unchanged set.
        var effective = options
        var reusedCount = 0
        if let previous = try await store.latestExportRun(destination: builder.destination.rawValue),
           previous.projectID == project.id {
            let valid = Self.verifiedResume(from: previous, outputDir: outputDir)
            if !valid.hashes.isEmpty {
                effective.overwriteExisting = false
                effective.resumeHashes = valid.hashes
                effective.resumeDurations = valid.durations
                reusedCount = valid.hashes.count
            }
        }

        let run = try await store.openExportRun(projectID: project.id, destination: builder.destination.rawValue)
        let recorder = ChapterRecorder(store: store, outputDir: outputDir, run: run)
        do {
            let bundle = try await builder.build(
                project: project,
                renders: renders,
                transcoder: transcoder,
                assets: assets,
                into: exportsRoot,
                options: effective,
                progress: { event in
                    progress(event)
                    recorder.note(event)
                }
            )
            let final = await recorder.finalize(bundle: bundle, status: .succeeded, finishedAt: clock.now)
            return Outcome(run: final, bundle: bundle, reusedFileCount: reusedCount)
        } catch is CancellationError {
            let final = await recorder.finalize(bundle: nil, status: .cancelled, finishedAt: clock.now)
            return Outcome(run: final, bundle: nil, reusedFileCount: reusedCount)
        } catch {
            let final = await recorder.finalize(bundle: nil, status: .failed, errorCode: String(describing: error), finishedAt: clock.now)
            throw error
        }
    }

    /// Files from `run` that still exist under `outputDir` with the recorded
    /// content hash. Anything missing or partial is excluded so it is rebuilt.
    private static func verifiedResume(from run: ExportRunRecord, outputDir: URL) -> (hashes: [String: String], durations: [String: TimeInterval]) {
        var hashes: [String: String] = [:]
        var durations: [String: TimeInterval] = [:]
        for (name, hash) in run.fileHashes {
            let url = outputDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let existing = try? SHA256Hex.hex(contentsOf: url),
                  existing == hash else { continue }
            hashes[name] = hash
            durations[name] = run.fileDurations[name] ?? 0
        }
        return (hashes, durations)
    }
}

/// Collects chapter-completion checkpoints from the builder's progress stream
/// and persists them to the run row as they arrive. `note` is synchronous (called
/// directly from the builder's `@Sendable` progress closure), so a
/// `.chapterFinished` event is captured exactly when the builder emits it with
/// no task-ordering race; `drain` applies the captured set in order.
private final class ChapterRecorder: @unchecked Sendable {
    private let store: any ProductionStore
    private let outputDir: URL
    private var run: ExportRunRecord
    private var completions: [ChapterCompletion] = []
    private let lock = NSLock()

    private struct ChapterCompletion {
        let filename: String
        let hash: String
        let size: Int64
        let duration: TimeInterval
    }

    init(store: any ProductionStore, outputDir: URL, run: ExportRunRecord) {
        self.store = store
        self.outputDir = outputDir
        self.run = run
    }

    /// Called from the builder's progress closure: hash the just-finished output
    /// and queue its checkpoint. Hashing one file is fast, and this is the
    /// durable-checkpoint point.
    func note(_ event: ExportProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard event.phase == .chapterFinished, let filename = event.currentFileName else { return }
        let url = outputDir.appendingPathComponent(filename)
        guard let hash = try? SHA256Hex.hex(contentsOf: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              let duration = event.completedDuration else { return }
        completions.append(ChapterCompletion(filename: filename, hash: hash, size: Int64(size), duration: duration))
    }

    /// Applies every queued checkpoint to the run row, one `updateExportRun`
    /// per chapter, so a crash after any of them leaves a partial-but-resumable
    /// record.
    func drain() async {
        let items: [ChapterCompletion]
        lock.lock()
        items = completions
        completions = []
        lock.unlock()
        for item in items {
            run.fileHashes[item.filename] = item.hash
            run.fileDurations[item.filename] = item.duration
            run.fileCount = run.fileHashes.count
            run.totalBytes += item.size
            run.outputPath = outputDir.path
            try? await store.updateExportRun(run)
        }
    }

    /// Drains pending checkpoints, then writes the terminal status. On success
    /// the authoritative file set comes from the produced `ExportBundle`.
    func finalize(
        bundle: ExportBundle?,
        status: ExportRunStatus,
        errorCode: String? = nil,
        finishedAt: Date
    ) async -> ExportRunRecord {
        await drain()
        if let bundle {
            var hashes: [String: String] = [:]
            var durations: [String: TimeInterval] = [:]
            for file in bundle.files {
                let name = file.url.lastPathComponent
                if !file.sha256.isEmpty { hashes[name] = file.sha256 }
                if let duration = file.duration { durations[name] = duration }
            }
            run.fileHashes = hashes
            run.fileDurations = durations
            run.fileCount = hashes.count
            run.totalBytes = bundle.totalBytes
            run.outputPath = bundle.rootURL.path
            run.status = status
            run.finishedAt = finishedAt
            try? await store.updateExportRun(run)
        } else {
            run.status = status
            run.errorCode = errorCode
            run.finishedAt = finishedAt
            try? await store.updateExportRun(run)
        }
        return run
    }
}
