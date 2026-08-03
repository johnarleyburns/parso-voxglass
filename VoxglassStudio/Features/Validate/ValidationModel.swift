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

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version {
            return build.map { "\(version) (\($0))" } ?? version
        }
        return "dev"
    }
}
