import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// WP-F acceptance (§16.12): the export run lifecycle.
///
/// - A successful run is promoted out of `.partial` staging and its per-file
///   hashes are recorded on the `export_run` row.
/// - A failed or cancelled run leaves `<slug>.partial` plus a `failed`/
///   `cancelled` row — the resume artifact.
/// - A `running` row (crash/interrupt) makes the wizard offer Resume.
/// - Re-export with `overwriteExisting == false` reports files whose hash
///   matches the previous run as "unchanged".
@MainActor
@Suite struct ExportResumeTests {

    private func exportsRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        project: AudiobookProject,
        store: any ProductionStore,
        renderer: any ChapterRenderable = TestChapterRenderer(),
        outputRoot: URL
    ) -> ExportModel {
        ExportModel(
            project: project,
            assets: InMemoryAssetStore(),
            renderer: renderer,
            transcoder: FakeTranscoder(),
            gate: LicenseGate(provider: FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))),
            store: store,
            outputRoot: outputRoot,
            now: { Date(timeIntervalSinceReferenceDate: 0) }
        )
    }

    private func libriVoxModel(
        store: any ProductionStore,
        renderer: any ChapterRenderable = TestChapterRenderer()
    ) throws -> (model: ExportModel, outputRoot: URL) {
        let root = try exportsRoot()
        let model = makeModel(project: ProjectFixtures.librivoxReady(), store: store, renderer: renderer, outputRoot: root)
        model.card = .librivox
        return (model, root)
    }

    @Test func successfulRunPromotesAndRecordsHashes() async throws {
        let store = InMemoryProductionStore()
        let (model, root) = try libriVoxModel(store: store)

        await model.runAndWait()

        #expect(model.error == nil)
        #expect(model.completedBundle != nil)
        #expect(model.step == .done)

        // The final directory is promoted: no `.partial` suffix anywhere.
        let finalDir = root.appendingPathComponent("LibriVox", isDirectory: true)
            .appendingPathComponent(PackagingSupport.directorySlug(ProjectFixtures.librivoxReady().metadata.title), isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: finalDir.path))
        let partial = finalDir.appendingPathExtension("partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        // The run row is closed `succeeded` with per-file hashes.
        let run = try await store.latestExportRun(destination: "librivox")
        #expect(run != nil)
        #expect(run?.status == .succeeded)
        #expect((run?.fileCount ?? 0) > 0)
        #expect(run?.fileHashes.isEmpty == false)
        #expect(run?.outputPath == finalDir.path)
    }

    @Test func failedExportLeavesPartialAndFailedRow() async throws {
        let store = InMemoryProductionStore()
        let (model, root) = try libriVoxModel(store: store, renderer: ThrowingChapterRenderer())

        await model.runAndWait()

        #expect(model.error != nil)
        #expect(model.step == .confirm)

        // The interrupted build stays at `<slug>.partial` for diagnosis.
        let slug = PackagingSupport.directorySlug(ProjectFixtures.librivoxReady().metadata.title)
        let partial = root.appendingPathComponent("LibriVox", isDirectory: true)
            .appendingPathComponent("\(slug).partial", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(model.partialDirectoryURL != nil)

        let run = try await store.latestExportRun(destination: "librivox")
        #expect(run?.status == .failed)
        #expect(run?.finishedAt != nil)
    }

    @Test func runningRunEnablesResumeOffer() async throws {
        let store = InMemoryProductionStore()
        // Simulate a crash mid-export: a row left `running`, no terminal state.
        let project = ProjectFixtures.librivoxReady()
        let interrupted = try await store.openExportRun(projectID: project.id, destination: "librivox")
        #expect(interrupted.status == .running)

        let (model, _) = try libriVoxModel(store: store)
        await model.loadRunState()

        #expect(model.hasResumableRun)
        #expect(model.runningRun?.id == interrupted.id)
    }

    @Test func reExportWithOverwriteFalseReportsUnchangedFiles() async throws {
        let store = InMemoryProductionStore()
        let (model, root) = try libriVoxModel(store: store)

        // First export: everything is produced fresh.
        await model.runAndWait()
        #expect(model.error == nil)
        let firstRun = try await store.latestExportRun(destination: "librivox")
        #expect(firstRun?.status == .succeeded)

        // Second export with overwriteExisting == false: deterministic content
        // means every file hash matches, so each is reported "unchanged".
        let (model2, _) = try libriVoxModel(store: store)
        model2.overwriteExisting = false
        await model2.runAndWait()

        #expect(model2.error == nil)
        let secondRun = try await store.latestExportRun(destination: "librivox")
        #expect(secondRun?.status == .succeeded)
        let unchanged = model2.completedBundle?.warnings.filter { $0.hasPrefix("unchanged:") } ?? []
        #expect(!unchanged.isEmpty)
        #expect((model2.completedBundle?.files.count ?? 0) == unchanged.count)
    }
}

/// A `ChapterRenderable` that always throws — used to exercise the failure
/// path of the export run lifecycle.
struct ThrowingChapterRenderer: ChapterRenderable {
    func render(
        _ plan: RenderPlan,
        to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ChapterRendering {
        throw ChapterRenderError.broken
    }
}

enum ChapterRenderError: Error {
    case broken
}
