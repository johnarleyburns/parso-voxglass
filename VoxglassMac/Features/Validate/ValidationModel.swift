import Foundation
import Observation
import VoxglassCore

/// Backs the Validation screen (spec §18.1.14). Runs the pure rule engine
/// against the current project for a chosen destination and exposes the report,
/// severity tallies, and an eligibility panel.
///
/// Validation is free for **every** destination (§15.7) — this model MUST NOT
/// read the entitlement gate (CI gate G-2); only the Export path may.
@Observable @MainActor
public final class ValidationModel {
    public private(set) var report: ValidationReport?
    public private(set) var isEvaluating = false
    public private(set) var error: String?
    public var target: DestinationID

    /// Routes a fix that needs a different surface (record, metadata, export…).
    /// The window shell sets this; `fixNext()` returns the navigation when set.
    public var onNavigate: ((ValidationFixNavigation) -> Void)?

    /// Re-analyzes a take's metrics on demand (§15.2 `reanalyzeTake`). The
    /// Studio wires the real analyzer; tests leave it nil.
    public var reanalyzeTake: ((UUID) async -> AudioQualityMetrics?)?

    public var eligibility: EligibilityProfile? { report?.eligibility }

    public var blockingCount: Int { report?.summary.blocking ?? 0 }
    public var warningCount: Int { report?.summary.warnings ?? 0 }
    public var passedCount: Int { report?.summary.passed ?? 0 }

    private let project: AudiobookProject
    private let store: any ProductionStore
    private let assets: any ContentAddressedStore

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        target: DestinationID = .librivox
    ) {
        self.project = project
        self.store = store
        self.assets = assets
        self.target = target
    }

    /// Runs (or re-runs) validation for the selected destination.
    public func evaluate() async {
        isEvaluating = true
        defer { isEvaluating = false }

        let profile = DestinationProfile.profile(for: target)
        let settings = project.profile.assembly
        let eligibility = EligibilityProfile.evaluate(project)

        var metrics: [UUID: AudioQualityMetrics] = [:]
        for paragraph in project.allParagraphs {
            guard let sid = paragraph.selectedTakeID,
                  let take = paragraph.takes.first(where: { $0.id == sid }),
                  let takeMetrics = take.metrics else { continue }
            metrics[take.id] = takeMetrics
        }

        let integrity = ProjectIntegrity.check(project, assets: assets, deep: false)
        let context = ValidationContext(integrityFindings: integrity)
        let issues = ValidationRuleEngine().evaluate(
            project: project,
            metrics: metrics,
            profile: profile,
            eligibility: eligibility,
            assembly: settings,
            context: context
        )

        // Summary: assembled chapter durations so the numbers agree with the
        // chapter-length rules the engine just evaluated.
        let builder = SegmentQueueBuilder()
        var totalDuration: TimeInterval = 0
        var overMax = 0
        for chapter in project.chapters {
            let duration = AssemblyDuration.duration(of: builder.build(.chapter(chapter.id), from: project, settings: settings))
            totalDuration += duration
            if let max = profile.maxFileDuration, duration > max { overMax += 1 }
        }

        let recorded = project.allParagraphs.count { $0.selectedTakeID != nil }
        let summary = ValidationSummary.from(
            issues: issues,
            totalParagraphs: project.allParagraphs.count,
            recordedParagraphs: recorded,
            totalDuration: totalDuration,
            chaptersOverMaxDuration: overMax
        )

        report = ValidationReport(
            destination: target,
            generatedAt: Date(),
            projectID: project.id,
            projectTitle: project.metadata.title,
            issues: issues,
            eligibility: eligibility,
            summary: summary,
            analyzerVersion: AudioMetricsCalculator.analyzerVersion,
            appVersion: Self.appVersion
        )
    }

    /// Resolved issues for the report, newest-first is not used; determinism
    /// matters, so issues keep engine order (document order).
    public var issues: [ValidationIssue] {
        report?.issues ?? []
    }

    public func issues(severity: Severity) -> [ValidationIssue] {
        issues.filter { $0.severity == severity }
    }

    // MARK: - Fix Next Issue (§15.2)

    /// The first blocking issue (document order) with a remedy, or nil.
    public var nextFixableBlockingIssue: ValidationIssue? {
        issues.first { $0.severity == .blocking && $0.fix != nil }
    }

    /// "Fix Next Issue": walks blocking issues in document order, performing
    /// store-level remedies inline and routing surface changes through
    /// `onNavigate`. Returns what happened so the view can re-evaluate.
    @discardableResult
    public func fixNext() async -> ValidationFixOutcome {
        guard let issue = nextFixableBlockingIssue, let fix = issue.fix else { return .none }
        switch fix {
        case .goToParagraph(let id):
            return navigate(.goToParagraph(id))
        case .goToChapter(let id):
            return navigate(.goToChapter(id))
        case .openMetadata(let field):
            return navigate(.openMetadata(field))
        case .openRights:
            return navigate(.openRights)
        case .recordParagraph(let id):
            return navigate(.recordParagraph(id))
        case .selectTake(let paragraphID, let takeID):
            do {
                try await store.setSelectedTake(takeID, forParagraph: paragraphID)
                await evaluate()
                return .performed("Selected take")
            } catch {
                return .failed("Could not select take: \(error.localizedDescription)")
            }
        case .clearPickup(let id):
            do {
                try await store.setReviewState(.unreviewed, forParagraph: id)
                await evaluate()
                return .performed("Cleared pickup flag")
            } catch {
                return .failed("Could not clear pickup: \(error.localizedDescription)")
            }
        case .reanalyzeTake(let takeID):
            guard let reanalyzeTake else { return .none }
            guard let metrics = await reanalyzeTake(takeID) else { return .none }
            do {
                try await store.setTakeMetrics(metrics, forTake: takeID)
                await evaluate()
                return .performed("Re-analyzed take")
            } catch {
                return .failed("Could not store metrics: \(error.localizedDescription)")
            }
        case .regenerateDisclaimers:
            return await regenerate(introOutro: true)
        case .regenerateCredits:
            return await regenerate(introOutro: false)
        case .applyMastering:
            return navigate(.exportWithMastering)
        case .splitChapter(let chapterID, let atParagraph):
            return navigate(.splitChapter(chapterID, atParagraph: atParagraph))
        case .chooseArtwork:
            return navigate(.chooseArtwork)
        case .setRetailSample:
            return navigate(.setRetailSample)
        }
    }

    /// §15.2 `validate.goToParagraph.<n>`: jump to a specific paragraph.
    public func goToParagraph(_ id: UUID) {
        onNavigate?(.goToParagraph(id))
    }

    // MARK: - Private

    private func navigate(_ navigation: ValidationFixNavigation) -> ValidationFixOutcome {
        onNavigate?(navigation)
        return .navigated(navigation)
    }

    private func regenerate(introOutro: Bool) async -> ValidationFixOutcome {
        do {
            var updated = try await store.load()
            let ids = UUIDGenerator()
            let clock = SystemClock()
            let generator: any ScriptGenerating = introOutro
                ? LibriVoxScriptGenerator()
                : RetailScriptGenerator()
            _ = ScriptApplier().apply(generator.plan(for: updated), to: &updated, ids: ids, clock: clock)
            try await store.save(updated)
            await evaluate()
            return .performed(introOutro ? "Regenerated LibriVox disclaimers" : "Regenerated retail credits")
        } catch {
            return .failed("Could not regenerate: \(error.localizedDescription)")
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version {
            return build.map { "\(version) (\($0))" } ?? version
        }
        return "dev"
    }
}

/// A fix that moves the user to a different surface (§15.2).
public enum ValidationFixNavigation: Sendable, Equatable {
    case goToParagraph(UUID)
    case goToChapter(UUID)
    case openMetadata(MetadataField)
    case openRights
    case recordParagraph(UUID)
    case exportWithMastering
    case splitChapter(UUID, atParagraph: UUID)
    case chooseArtwork
    case setRetailSample
}

/// What "Fix Next Issue" did.
public enum ValidationFixOutcome: Sendable, Equatable {
    case performed(String)
    case navigated(ValidationFixNavigation)
    case failed(String)
    case none
}
