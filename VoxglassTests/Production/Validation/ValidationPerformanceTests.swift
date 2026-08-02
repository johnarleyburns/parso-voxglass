import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Scale/correctness smoke for the S7 acceptance path — the `typical()` fixture
/// validating for all five destinations and the report renderer round-tripping.
/// The **timing** budget for full validation lives in the serialized
/// `PerformanceBudgetTests` suite (`VoxglassPerformanceTests`, §19.1), which is
/// the repo's established home for wall-clock assertions; this parallel suite
/// deliberately contains no clock.
@Suite struct ValidationPerformanceTests {

    private func evaluate(_ project: AudiobookProject, target: DestinationID) -> [ValidationIssue] {
        let profile = DestinationProfile.profile(for: target)
        let eligibility = EligibilityProfile.evaluate(project)
        return ValidationRuleEngine().evaluate(
            project: project, metrics: [:], profile: profile,
            eligibility: eligibility, assembly: project.profile.assembly
        )
    }

    @Test func typicalFixtureValidatesAcrossAllFiveDestinations() {
        let project = ProjectFixtures.typical()
        for target in DestinationID.allCases {
            let issues = evaluate(project, target: target)
            #expect(!issues.isEmpty)
            let summary = ValidationSummary.from(
                issues: issues,
                totalParagraphs: project.allParagraphs.count,
                recordedParagraphs: project.recordedCount,
                totalDuration: 0,
                chaptersOverMaxDuration: 0
            )
            #expect(summary.totalParagraphs == project.totalCount)
            #expect(summary.blocking + summary.warnings <= issues.count)
            #expect(summary.passed >= 0)
        }
    }

    @Test func stressFixtureProducesConsistentCounts() {
        let project = ProjectFixtures.stress(paragraphs: 3_000)
        let issues = evaluate(project, target: .librivox)
        #expect(issues.count == Set(issues.map(\.id)).count)
        #expect(issues.contains { $0.code == .missingAcceptedTake })
    }

    @Test func reportRendererJSONRoundTrips() throws {
        let project = ProjectFixtures.tiny()
        let issues = evaluate(project, target: .librivox)
        // Whole-second timestamp: the renderer writes ISO-8601 (§16.13's
        // `"generatedAt": "2026-08-14T18:22:09Z"`), which has second precision.
        let generatedAt = Date(timeIntervalSince1970: 1_752_600_000)
        let report = ValidationReport(
            destination: .librivox,
            generatedAt: generatedAt,
            projectID: project.id,
            projectTitle: project.metadata.title,
            issues: issues,
            eligibility: EligibilityProfile.evaluate(project),
            summary: ValidationSummary.from(issues: issues, totalParagraphs: project.totalCount, recordedParagraphs: project.recordedCount, totalDuration: 0, chaptersOverMaxDuration: 0),
            analyzerVersion: AudioMetricsCalculator.analyzerVersion,
            appVersion: "test"
        )
        let data = try ValidationReportRenderer().json(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ValidationReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.destination == .librivox)
        #expect(decoded.issues.count == issues.count)
    }

    @Test func reportRendererHTMLIsSelfContained() {
        let project = ProjectFixtures.tiny()
        let issues = evaluate(project, target: .librivox)
        let report = ValidationReport(
            destination: .librivox, generatedAt: Date(), projectID: project.id,
            projectTitle: project.metadata.title, issues: issues,
            eligibility: EligibilityProfile.evaluate(project),
            summary: ValidationSummary.from(issues: issues, totalParagraphs: project.totalCount, recordedParagraphs: project.recordedCount, totalDuration: 0, chaptersOverMaxDuration: 0),
            analyzerVersion: AudioMetricsCalculator.analyzerVersion, appVersion: "test"
        )
        let html = ValidationReportRenderer().html(report)
        #expect(html.contains(project.metadata.title))
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(!html.contains("<script"))  // no external assets
        let plain = ValidationReportRenderer().plainText(report)
        #expect(plain.contains("Validation report"))
    }
}
