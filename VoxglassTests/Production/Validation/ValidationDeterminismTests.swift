import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Issue IDs and ordering must be deterministic (§15.1): re-running validation
/// never reshuffles the list and a fixed issue can be diffed away.
@Suite struct ValidationDeterminismTests {

    private func run(_ project: AudiobookProject, target: DestinationID) -> [ValidationIssue] {
        let profile = DestinationProfile.profile(for: target)
        let eligibility = EligibilityProfile.evaluate(project)
        return ValidationRuleEngine().evaluate(
            project: project,
            metrics: [:],
            profile: profile,
            eligibility: eligibility,
            assembly: project.profile.assembly
        )
    }

    @Test func identicalRunsProduceIdenticalIssues() {
        let project = ProjectFixtures.typical()
        let first = run(project, target: .librivox)
        let second = run(project, target: .librivox)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.code) == second.map(\.code))
        #expect(first.map(\.severity) == second.map(\.severity))
        #expect(first == second)
    }

    @Test func deterministicIssueIDsAreStable() {
        let chapterID = UUID()
        let paragraphID = UUID()
        let code: IssueCode = .missingAcceptedTake
        let a = ValidationIssue.deterministicID(code: code, chapterID: chapterID, paragraphID: paragraphID)
        let b = ValidationIssue.deterministicID(code: code, chapterID: chapterID, paragraphID: paragraphID)
        #expect(a == b)
        // Different paragraph ⇒ different ID.
        let c = ValidationIssue.deterministicID(code: code, chapterID: chapterID, paragraphID: UUID())
        #expect(a != c)
        // Different code ⇒ different ID.
        let d = ValidationIssue.deterministicID(code: .emptyChapter, chapterID: chapterID, paragraphID: paragraphID)
        #expect(a != d)
    }

    @Test func deterministicAcrossAllDestinations() {
        for target in DestinationID.allCases {
            let project = ProjectFixtures.typical()
            let first = run(project, target: target)
            let second = run(project, target: target)
            #expect(first.map(\.id) == second.map(\.id), "destination \(target.rawValue) reshuffled between runs")
        }
    }

    @Test func issueIDsDifferAcrossRulesAndLocations() {
        let project = ProjectFixtures.typical()
        let issues = run(project, target: .librivox)
        let ids = Set(issues.map(\.id))
        #expect(ids.count == issues.count, "duplicate issue IDs in a single run")
    }
}
