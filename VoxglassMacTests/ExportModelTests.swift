import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// The S9 acceptance tests (§20 S9): the Export wizard model's gate contract.
///
/// - LibriVox and Internet Archive exports **complete** with a
///   `FakeLicenseProvider` that fails on any access — proving the free path
///   never consults the gate.
/// - Retail export **requires Pro**, the gate is checked exactly once at the
///   step 2→3 transition, and selections are preserved across purchase.
@MainActor
@Suite struct ExportModelTests {

    private func exportsRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        project: AudiobookProject,
        provider: FakeLicenseProvider
    ) throws -> ExportModel {
        ExportModel(
            project: project,
            assets: InMemoryAssetStore(),
            renderer: TestChapterRenderer(),
            transcoder: FakeTranscoder(),
            gate: LicenseGate(provider: provider),
            store: InMemoryProductionStore(),
            outputRoot: try exportsRoot(),
            now: { Date(timeIntervalSinceReferenceDate: 0) }
        )
    }

    private func iaReadyProject() -> AudiobookProject {
        var project = ProjectFixtures.librivoxReady()
        project.metadata.archiveIdentifier = "ready_book_author_narrator"
        project.rights.licenseURL = URL(string: "https://creativecommons.org/publicdomain/mark/1.0/")
        return project
    }

    // MARK: - Free path never consults the gate

    @Test func librivoxExportCompletesWithoutConsultingGate() async throws {
        let provider = FakeLicenseProvider(entitlement: .free, failEveryCall: true)
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: provider)

        model.card = .librivox
        _ = await model.next()                 // scope → destination
        let reached = await model.next()       // destination → confirm
        #expect(reached)
        #expect(model.step == .confirm)
        #expect(provider.calls.isEmpty, "LibriVox is free — the gate must never be consulted")

        await model.runAndWait()
        #expect(model.completedBundle != nil)
        #expect(model.error == nil)
        #expect(provider.calls.isEmpty, "The free export path must not consult the gate at any point")
    }

    @Test func internetArchiveExportCompletesWithoutConsultingGate() async throws {
        let provider = FakeLicenseProvider(entitlement: .free, failEveryCall: true)
        let model = try makeModel(project: iaReadyProject(), provider: provider)

        model.card = .internetArchive
        model.includeMP3Derivatives = true
        model.useTestCollection = true
        _ = await model.next()
        let reached = await model.next()
        #expect(reached)
        #expect(provider.calls.isEmpty)

        await model.runAndWait()
        #expect(model.completedBundle != nil)
        #expect(model.error == nil)
        #expect(model.step == .done)
        #expect(provider.calls.isEmpty, "The free export path must not consult the gate at any point")
    }

    // MARK: - Retail gate

    @Test func retailRequiresPro_gateCheckedExactlyOnce() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: provider)

        model.card = .retail
        model.retailProfile = .appleBooksAggregator
        model.scope = .chapters([model.project.chapters[0].id])
        _ = await model.next()                 // scope → destination (no gate)

        let reached = await model.next()       // destination → confirm (gate here)
        #expect(!reached)
        #expect(model.step == .destination, "Retail must stop at destination selection without Pro")
        #expect(model.showPurchase)
        #expect(provider.calls == [.entitlement], "Gate checked exactly once at step 2→3")

        // Selections preserved across the (failed) transition.
        #expect(model.retailProfile == .appleBooksAggregator)
        #expect(model.scope == .chapters([model.project.chapters[0].id]))
    }

    @Test func retailResumesAfterPurchase_preservingSelections() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: provider)
        model.card = .retail
        model.retailProfile = .appleBooksAggregator
        model.includeMP3Derivatives = true
        _ = await model.next()
        let reached = await model.next()
        #expect(!reached)
        #expect(model.step == .destination)

        // Simulate the StoreKit sandbox confirming the purchase.
        provider.setEntitlement(.pro(since: Date(timeIntervalSinceReferenceDate: 0)))

        let resumed = await model.resumeAfterPurchase()
        #expect(resumed)
        #expect(model.step == .confirm)
        #expect(provider.calls.count == 2, "Purchase resume re-checks the gate exactly once more")
        #expect(model.retailProfile == .appleBooksAggregator, "Selections survive the purchase sheet")
        #expect(model.includeMP3Derivatives, "Option selections survive the purchase sheet")
    }

    // MARK: - Navigation & validation

    @Test func freeDestinationReachesConfirmWithBlockingSummary() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: provider)
        model.card = .librivox

        #expect(model.step == .scope)
        _ = await model.next()
        #expect(model.step == .destination)

        _ = await model.next()
        #expect(model.step == .confirm)
        #expect(model.blockingCount == 0, "librivoxReady passes LibriVox validation")
        #expect(model.canRun)
        #expect(provider.calls.isEmpty)
    }

    @Test func backNavigationReturnsThroughSteps() async throws {
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: FakeLicenseProvider(entitlement: .free))
        model.card = .librivox
        _ = await model.next()
        #expect(model.step == .destination)
        model.back()
        #expect(model.step == .scope)
    }

    @Test func runDoesNothingWithoutDestination() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let model = try makeModel(project: ProjectFixtures.librivoxReady(), provider: provider)
        await model.runAndWait()
        #expect(model.isRunning == false)
        #expect(model.completedBundle == nil)
        #expect(provider.calls.isEmpty)
    }
}

/// Minimal deterministic `ChapterRenderable`: writes a tiny file (the
/// `FakeTranscoder` copies it, so hashing behaves) and reports a duration
/// derived from the plan. No AVFoundation encode.
struct TestChapterRenderer: ChapterRenderable {
    func render(
        _ plan: RenderPlan,
        to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ChapterRendering {
        try? FileManager.default.removeItem(at: url)
        try Data([0x63, 0x61, 0x66, 0x66]).write(to: url) // "caff"
        let duration = plan.segments.reduce(0.0) { partial, segment in
            partial + segment.leadingSilence + (segment.trim.upperBound - segment.trim.lowerBound) + segment.trailingSilence
        }
        progress(1)
        return ChapterRendering(
            ref: AudioAssetReference(sha256: "test-render", relativePath: url.lastPathComponent, byteCount: 4, contentType: "audio/caf"),
            duration: duration,
            paragraphOffsets: [:]
        )
    }
}
