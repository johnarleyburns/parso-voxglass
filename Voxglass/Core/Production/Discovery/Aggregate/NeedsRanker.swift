import Foundation

/// Pure, deterministic ranking (NARRATION_NEEDS_SPEC §7):
/// 1. signal priority, 2. actionability for this platform, 3. taste,
/// 4. shortest-first within the short rail, 5. deterministic id tie-break.
public struct NeedsRanker: Sendable {
    public init() {}

    /// `taste` is the existing on-device reco signal: author/title tokens the
    /// user has engaged with. Empty means neutral.
    public func rank(_ needs: [NarrationNeed], for platform: Platform, taste: [String] = []) -> [NarrationNeed] {
        let tasteTokens = Set(taste.map { NeedID.normalize($0) })
        return needs.sorted { lhs, rhs in
            let lhsSignal = lhs.signal.priority
            let rhsSignal = rhs.signal.priority
            if lhsSignal != rhsSignal { return lhsSignal < rhsSignal }

            // Actionability: needs narratable on this platform rank above
            // others within the same rail (N-1: every need is narratable on
            // iPhone, so this is a neutral tie-break rather than a gate).
            let lhsActionable = lhs.narratableOn.contains(platform) ? 0 : 1
            let rhsActionable = rhs.narratableOn.contains(platform) ? 0 : 1
            if lhsActionable != rhsActionable { return lhsActionable < rhsActionable }

            // Taste: poetry listeners → poems first; favorited author → their works.
            let lhsTaste = tasteScore(lhs, tokens: tasteTokens)
            let rhsTaste = tasteScore(rhs, tokens: tasteTokens)
            if lhsTaste != rhsTaste { return lhsTaste > rhsTaste }

            // Shortest-first within the short rail (fastest first win).
            if lhs.work.lengthClass == .short,
               rhs.work.lengthClass == .short,
               lhs.work.estSeconds != rhs.work.estSeconds {
                return lhs.work.estSeconds < rhs.work.estSeconds
            }

            // Deterministic tie-break.
            return lhs.id < rhs.id
        }
    }

    private func tasteScore(_ need: NarrationNeed, tokens: Set<String>) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var score = 0
        if tokens.contains(NeedID.normalize(need.work.author)) { score += 2 }
        if tokens.contains(NeedID.normalize(need.work.title)) { score += 1 }
        return score
    }
}
