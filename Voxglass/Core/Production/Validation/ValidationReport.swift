import Foundation

/// The full outcome of a validation run for one destination (§15.1).
///
/// `generatedAt` is injected, never read from the clock here, so Core/Production
/// stays determinism-gated (grep gate G-7 forbids bare clock reads in this tree).
public struct ValidationReport: Sendable, Codable, Equatable {
    public var destination: DestinationID
    public var generatedAt: Date
    public var projectID: UUID
    public var projectTitle: String
    public var issues: [ValidationIssue]
    public var eligibility: EligibilityProfile
    public var summary: ValidationSummary
    public var analyzerVersion: Int
    public var appVersion: String

    public init(
        destination: DestinationID,
        generatedAt: Date,
        projectID: UUID,
        projectTitle: String,
        issues: [ValidationIssue],
        eligibility: EligibilityProfile,
        summary: ValidationSummary,
        analyzerVersion: Int,
        appVersion: String
    ) {
        self.destination = destination
        self.generatedAt = generatedAt
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.issues = issues
        self.eligibility = eligibility
        self.summary = summary
        self.analyzerVersion = analyzerVersion
        self.appVersion = appVersion
    }
}

/// Counts for the Validation screen's sidebar and the export wizard (§15.1).
///
/// `passed` counts recorded paragraphs that produced no issue at all, so it is
/// meaningful next to the per-paragraph issue tallies.
public struct ValidationSummary: Sendable, Codable, Equatable {
    public var blocking: Int
    public var warnings: Int
    public var passed: Int
    public var totalParagraphs: Int
    public var recordedParagraphs: Int
    public var totalDuration: TimeInterval
    public var chaptersOverMaxDuration: Int

    public init(
        blocking: Int = 0,
        warnings: Int = 0,
        passed: Int = 0,
        totalParagraphs: Int = 0,
        recordedParagraphs: Int = 0,
        totalDuration: TimeInterval = 0,
        chaptersOverMaxDuration: Int = 0
    ) {
        self.blocking = blocking
        self.warnings = warnings
        self.passed = passed
        self.totalParagraphs = totalParagraphs
        self.recordedParagraphs = recordedParagraphs
        self.totalDuration = totalDuration
        self.chaptersOverMaxDuration = chaptersOverMaxDuration
    }

    public static func from(issues: [ValidationIssue], totalParagraphs: Int, recordedParagraphs: Int, totalDuration: TimeInterval, chaptersOverMaxDuration: Int) -> ValidationSummary {
        var blocking = 0
        var warnings = 0
        var touchedParagraphs = Set<UUID>()
        for issue in issues {
            switch issue.severity {
            case .blocking: blocking += 1
            case .warning: warnings += 1
            case .passed: break
            }
            if let pid = issue.paragraphID { touchedParagraphs.insert(pid) }
        }
        let passed = max(0, recordedParagraphs - touchedParagraphs.count)
        return ValidationSummary(
            blocking: blocking,
            warnings: warnings,
            passed: passed,
            totalParagraphs: totalParagraphs,
            recordedParagraphs: recordedParagraphs,
            totalDuration: totalDuration,
            chaptersOverMaxDuration: chaptersOverMaxDuration
        )
    }
}
