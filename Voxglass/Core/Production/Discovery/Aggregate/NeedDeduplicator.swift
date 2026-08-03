import Foundation

/// Unions rung outputs by `NeedID`, merges provenance, and keeps the strongest
/// signal — pure and deterministic given inputs (NARRATION_NEEDS_SPEC §2.2, §7).
public struct NeedDeduplicator: Sendable {
    public init() {}

    public func dedupe(_ needs: [NarrationNeed]) -> [NarrationNeed] {
        var byID: [String: NarrationNeed] = [:]
        var order: [String] = []
        for need in needs {
            if byID[need.id] == nil {
                order.append(need.id)
            }
            byID[need.id] = merge(existing: byID[need.id], incoming: need)
        }
        return order.compactMap { byID[$0] }
    }

    /// Merge two records of the same work: union sources, keep the earliest
    /// `firstSeen`, the latest `lastConfirmed`, the stronger signal, the higher
    /// strength, the submittable grade, and any thread URL.
    private func merge(existing: NarrationNeed?, incoming: NarrationNeed) -> NarrationNeed {
        guard let existing else { return incoming }
        var sources = existing.provenance.sources
        for source in incoming.provenance.sources where !sources.contains(source) {
            sources.append(source)
        }

        let signal = min(existing.signal, incoming.signal) // Comparable: earlier = stronger
        let strength = max(existing.strength, incoming.strength)
        let firstSeen = min(existing.provenance.firstSeen, incoming.provenance.firstSeen)
        let lastConfirmed = max(existing.provenance.lastConfirmed, incoming.provenance.lastConfirmed)
        let threadURL = incoming.provenance.libriVoxThreadURL ?? existing.provenance.libriVoxThreadURL
        let editionYear = incoming.provenance.editionYear ?? existing.provenance.editionYear

        var work = existing.work
        if incoming.isSubmittable, !existing.isSubmittable {
            work = incoming.work
        } else if existing.isSubmittable {
            work = existing.work
        } else if work.text == nil {
            work = incoming.work
        }
        work.pinnedWeekOf = work.pinnedWeekOf ?? incoming.work.pinnedWeekOf
        work.pinnedMonthOf = work.pinnedMonthOf ?? incoming.work.pinnedMonthOf
        work.sourceEPUBURL = work.sourceEPUBURL ?? incoming.work.sourceEPUBURL

        return NarrationNeed(
            id: existing.id,
            work: work,
            signal: signal,
            strength: strength,
            provenance: NeedProvenance(
                sources: sources,
                firstSeen: firstSeen,
                lastConfirmed: lastConfirmed,
                pdBasis: strongerPD(existing.provenance.pdBasis, incoming.provenance.pdBasis),
                libriVoxThreadURL: threadURL,
                editionYear: editionYear
            ),
            expiresAt: earlierExpiry(existing.expiresAt, incoming.expiresAt)
        )
    }

    private func strongerPD(_ a: PDBasis, _ b: PDBasis) -> PDBasis {
        // A verified basis beats an unverified one; usOnly is kept only if nothing else.
        switch (a, b) {
        case (.unverified, _): return b
        case (_, .unverified): return a
        case (.usOnly, _): return b
        case (_, .usOnly): return a
        default: return a
        }
    }

    private func earlierExpiry(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, .some): return b
        case (.some, nil): return a
        case (.some(let a), .some(let b)): return min(a, b)
        }
    }
}
