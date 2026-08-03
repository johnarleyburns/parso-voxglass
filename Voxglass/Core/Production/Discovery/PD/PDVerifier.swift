import Foundation

/// The PD gate with a soft landing (NARRATION_NEEDS_SPEC §6, G-16).
///
/// Runs on every candidate before a `.submittable` grade may be assigned. It
/// never throws and never blocks UI; it downgrades. A need whose basis ends up
/// `.unverified` MUST NOT be `.submittable` — the aggregator normalizes it to
/// `.practice` so the user sees a clean set where every LibriVox-ready item is
/// genuinely ready, never an error.
public struct PDVerifier: Sendable {
    public init() {}

    /// Re-derives a work's PD basis from its evidence.
    public func verify(
        existing: PDBasis,
        sourcePageURL: URL?,
        editionYear: Int?,
        currentYear: Int
    ) -> PDBasis {
        if let host = sourcePageURL?.host {
            let lower = host.lowercased()
            if lower.hasSuffix("gutenberg.org") {
                // US-PD by Project Gutenberg policy.
                return .gutenbergSourced
            }
            if lower.hasSuffix("archive.org"),
               let year = editionYear,
               year <= currentYear - NeedsDiscoveryConstants.rollingCopyrightLine {
                // Rolling US line: 1930 in 2026, 1931 in 2027 — computed, never hard-coded.
                return .iaVerifiedEdition
            }
        }
        // Pre-verified curations (seed / pipeline snapshot) keep their basis.
        switch existing {
        case .curatorVerified, .usOnly:
            return existing
        case .gutenbergSourced, .iaVerifiedEdition, .unverified:
            return .unverified
        }
    }

    /// Convenience over a full need's provenance.
    public func verify(_ need: NarrationNeed, currentYear: Int) -> PDBasis {
        verify(
            existing: need.provenance.pdBasis,
            sourcePageURL: need.work.sourcePageURL,
            editionYear: need.provenance.editionYear,
            currentYear: currentYear
        )
    }
}
