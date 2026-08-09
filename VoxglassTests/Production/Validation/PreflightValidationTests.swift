import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P7 acceptance (spec §12.2): the four iPhone issue codes and their fix
/// actions. Hydration, storage, and backup state arrive through
/// `ValidationContext.exportPreflight`; `routeNotRetailReady` is computed from
/// the *recorded* route history (§7.1) for retail destinations only.
@Suite struct PreflightValidationTests {

    private static func project(routeClass: CaptureRouteClass? = nil) -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let pID = ids.next()
        let takeID = ids.next()
        let text = "A recorded paragraph for the preflight test."
        let hash = SHA256Hex.hex(Data(text.utf8))
        let take = Take(
            id: takeID,
            paragraphID: pID,
            assetRef: AudioAssetReference(
                sha256: "preflight-sha",
                relativePath: "Audio/Original/pr/ef/preflight.wav",
                byteCount: 4_000,
                contentType: "public.wav"
            ),
            origin: .recorded,
            recordedAt: clock.now,
            duration: 4.0,
            format: AudioFormatDescription(sampleRate: 44_100, channels: 1, codec: "pcm"),
            textHashAtRecording: hash,
            routeClass: routeClass
        )
        let paragraph = Paragraph(id: pID, ordinal: 0, text: text, textHash: hash, takes: [take], selectedTakeID: takeID)
        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter 1", paragraphs: [paragraph])
        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Preflight Book", author: "Author", narrator: "Narrator"),
            chapters: [chapter],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    private static func run(
        _ project: AudiobookProject,
        target: DestinationID,
        preflight: ExportPreflightContext? = nil
    ) -> [ValidationIssue] {
        ValidationRuleEngine().evaluate(
            project: project,
            metrics: PackagingSupport.selectedTakeMetrics(project),
            profile: DestinationProfile.profile(for: target),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly,
            context: ValidationContext(exportPreflight: preflight)
        )
    }

    private static func only(_ code: IssueCode, _ issues: [ValidationIssue]) -> [ValidationIssue] {
        issues.filter { $0.code == code }
    }

    // MARK: - assetRemoteOnlyForExport

    @Test func assetRemoteOnlyForExportBlocksWithHydrateFix() {
        let preflight = ExportPreflightContext(remoteHydrationBytes: 3_000_000_000, remoteHydrationChapterCount: 3)
        let issues = Self.run(Self.project(), target: .librivox, preflight: preflight)
        let hits = Self.only(.assetRemoteOnlyForExport, issues)
        #expect(hits.count == 1)
        #expect(hits[0].severity == .blocking)
        #expect(hits[0].fix == .hydrateAssets)
        #expect(hits[0].measured == 3_000_000_000)
    }

    @Test func assetRemoteOnlyForExportAbsentWhenEverythingLocal() {
        let issues = Self.run(Self.project(), target: .internetArchive, preflight: ExportPreflightContext(remoteHydrationBytes: 0))
        #expect(Self.only(.assetRemoteOnlyForExport, issues).isEmpty)
    }

    // MARK: - localStorageInsufficient

    @Test func localStorageInsufficientBlocksWithManageStorageFix() {
        let preflight = ExportPreflightContext(storageRequiredBytes: 10_000_000_000, storageAvailableBytes: 4_000_000_000)
        let issues = Self.run(Self.project(), target: .internetArchive, preflight: preflight)
        let hits = Self.only(.localStorageInsufficient, issues)
        #expect(hits.count == 1)
        #expect(hits[0].severity == .blocking)
        #expect(hits[0].fix == .manageStorage)
        #expect(hits[0].measured == 10_000_000_000)
        #expect(hits[0].expected?.contains("GB available") == true)
    }

    @Test func localStorageSufficientDoesNotFire() {
        let preflight = ExportPreflightContext(storageRequiredBytes: 4_000_000_000, storageAvailableBytes: 10_000_000_000)
        let issues = Self.run(Self.project(), target: .internetArchive, preflight: preflight)
        #expect(Self.only(.localStorageInsufficient, issues).isEmpty)
    }

    // MARK: - backupNotVerified

    @Test func backupNotVerifiedWarnsWithBackupNowFix() {
        let preflight = ExportPreflightContext(unverifiedSelectedTakeHashes: ["preflight-sha"])
        let issues = Self.run(Self.project(), target: .internetArchive, preflight: preflight)
        let hits = Self.only(.backupNotVerified, issues)
        #expect(hits.count == 1)
        #expect(hits[0].severity == .warning)
        #expect(hits[0].fix == .backupNow)
    }

    @Test func backupVerifiedDoesNotFire() {
        let issues = Self.run(Self.project(), target: .internetArchive, preflight: ExportPreflightContext())
        #expect(Self.only(.backupNotVerified, issues).isEmpty)
    }

    // MARK: - routeNotRetailReady

    @Test func draftOnlyRouteWarnsOnRetailOnly() {
        let project = Self.project(routeClass: .draftOnly)
        let retail = Self.run(project, target: .acx)
        let hits = Self.only(.routeNotRetailReady, retail)
        #expect(hits.count == 1)
        #expect(hits[0].severity == .warning)
        #expect(hits[0].fix == .openAudioSetup)

        // LibriVox / Internet Archive are unaffected (§7.1).
        #expect(Self.only(.routeNotRetailReady, Self.run(project, target: .librivox)).isEmpty)
        #expect(Self.only(.routeNotRetailReady, Self.run(project, target: .internetArchive)).isEmpty)
    }

    @Test func communityReadyAndRetailReadyRoutesDoNotWarn() {
        #expect(Self.only(.routeNotRetailReady, Self.run(Self.project(routeClass: .communityReady), target: .acx)).isEmpty)
        #expect(Self.only(.routeNotRetailReady, Self.run(Self.project(routeClass: .retailReady), target: .appleBooksAggregator)).isEmpty)
    }

    // MARK: - ExportPreflight.compute feeds the context

    @Test func preflightComputeDerivesHydrationAndUnverifiedState() {
        let project = Self.project()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let chapterID = project.chapters[0].id

        // Remote-only selected take → hydration plan; localOnly take → unverified.
        let remote = ProductionAssetRecord(
            id: ids.next(), sha256: "preflight-sha", byteCount: 4_000,
            state: .remoteOnly, chapterID: chapterID, lastAccessedAt: clock.now, remoteAssetID: "ck.asset.1"
        )
        let result = ExportPreflight.compute(
            project: project,
            assets: [remote],
            scope: .wholeBook,
            freeBytes: 12_000_000_000
        )
        #expect(result.hydrationPlan.byteCount == 4_000)
        #expect(result.hydrationPlan.blockingAssetIDs == [remote.id])
        #expect(result.remoteHydrationChapterCount == 1)
        #expect(result.storageRequiredBytes == 4_000)
        #expect(result.storageAvailableBytes == 12_000_000_000)
        #expect(result.unverifiedSelectedTakeHashes.isEmpty)

        let context = result.exportPreflightContext
        #expect(context.remoteHydrationBytes == 4_000)
        #expect(context.remoteHydrationChapterCount == 1)
        #expect(context.storageAvailableBytes == 12_000_000_000)
        #expect(context.unverifiedSelectedTakeHashes.isEmpty)
    }

    @Test func preflightComputeMarksLocalOnlySelectedTakesUnverified() {
        let project = Self.project()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let local = ProductionAssetRecord(
            id: ids.next(), sha256: "preflight-sha", byteCount: 4_000,
            state: .localOnly, chapterID: project.chapters[0].id, lastAccessedAt: clock.now
        )
        let result = ExportPreflight.compute(project: project, assets: [local], scope: .wholeBook, freeBytes: 1_000_000_000)
        #expect(result.hydrationPlan.byteCount == 0)
        #expect(result.unverifiedSelectedTakeHashes == ["preflight-sha"])
        let issues = Self.run(project, target: .internetArchive, preflight: result.exportPreflightContext)
        #expect(Self.only(.backupNotVerified, issues).count == 1)
    }
}
