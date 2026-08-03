import Foundation
import Testing
import VoxglassCore

@Suite struct PDVerifierTests {

    let verifier = PDVerifier()

    @Test func gutenbergHost_isGutenbergSourced() {
        let basis = verifier.verify(
            existing: .unverified,
            sourcePageURL: URL(string: "https://www.gutenberg.org/ebooks/84"),
            editionYear: nil,
            currentYear: 2026
        )
        #expect(basis == .gutenbergSourced)
    }

    @Test func archiveEditionWithinRollingLine_isIAVerified() {
        let basis = verifier.verify(
            existing: .unverified,
            sourcePageURL: URL(string: "https://archive.org/details/some-book"),
            editionYear: 1930,
            currentYear: 2026
        )
        #expect(basis == .iaVerifiedEdition)
    }

    @Test func tooRecentArchiveEdition_isUnverified() {
        let basis = verifier.verify(
            existing: .unverified,
            sourcePageURL: URL(string: "https://archive.org/details/some-book"),
            editionYear: 1995,
            currentYear: 2026
        )
        #expect(basis == .unverified)
    }

    @Test func usOnlyTagIsPreserved() {
        let basis = verifier.verify(
            existing: .usOnly,
            sourcePageURL: nil,
            editionYear: nil,
            currentYear: 2026
        )
        #expect(basis == .usOnly)
    }

    @Test func curatorVerifiedSeedIsPreserved() {
        let basis = verifier.verify(
            existing: .curatorVerified,
            sourcePageURL: nil,
            editionYear: nil,
            currentYear: 2026
        )
        #expect(basis == .curatorVerified)
    }

    @Test func rollingYearCeilingIsComputed() {
        // 1930 in 2026 → PD; 1931 in 2026 → not yet; 1931 in 2027 → PD.
        let p1930_2026 = verifier.verify(existing: .unverified, sourcePageURL: URL(string: "https://archive.org/details/a"), editionYear: 1930, currentYear: 2026)
        let p1931_2026 = verifier.verify(existing: .unverified, sourcePageURL: URL(string: "https://archive.org/details/a"), editionYear: 1931, currentYear: 2026)
        let p1931_2027 = verifier.verify(existing: .unverified, sourcePageURL: URL(string: "https://archive.org/details/a"), editionYear: 1931, currentYear: 2027)
        #expect(p1930_2026 == .iaVerifiedEdition)
        #expect(p1931_2026 == .unverified)
        #expect(p1931_2027 == .iaVerifiedEdition)
    }

    @Test func noEvidence_isUnverifiedAndCannotBeSubmittable() {
        let basis = verifier.verify(existing: .unverified, sourcePageURL: nil, editionYear: nil, currentYear: 2026)
        #expect(basis == .unverified)
    }
}
