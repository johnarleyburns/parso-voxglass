import Foundation

public struct ListeningHistoryEntry: Equatable {
    public var authors: [String]
    public var subjects: [String]
    public var languages: [String]
    public var listenedSeconds: Double
    public var capturedSignalIncrement: Double
    public var isFavorite: Bool

    public init(
        authors: [String] = [],
        subjects: [String] = [],
        languages: [String] = [],
        listenedSeconds: Double = 0,
        capturedSignalIncrement: Double = 0,
        isFavorite: Bool = false
    ) {
        self.authors = authors
        self.subjects = subjects
        self.languages = languages
        self.listenedSeconds = listenedSeconds
        self.capturedSignalIncrement = capturedSignalIncrement
        self.isFavorite = isFavorite
    }
}

public struct TermWeight: Equatable {
    public let axis: String
    public let term: String
    public let weight: Double

    public init(axis: String, term: String, weight: Double) {
        self.axis = axis
        self.term = term
        self.weight = weight
    }
}

public enum RecommendationPipeline {

    public static func termWeights(
        history: [ListeningHistoryEntry],
        onboardingSelectionIDs: Set<String> = []
    ) -> [TermWeight] {
        var weights: [TermKey: Double] = [:]

        for entry in history {
            let historyWeight = entry.listenedSeconds > 0
                ? historyIncrement(forSeconds: entry.listenedSeconds)
                : 0
            let signalWeight = entry.capturedSignalIncrement
            let favoriteWeight = entry.isFavorite
                ? RecommendationConstants.favoriteBoost
                : 0
            let contribution = max(historyWeight, signalWeight, favoriteWeight)
            guard contribution > 0 else { continue }

            let dedupedAuthors = Set(entry.authors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
            let dedupedSubjects = Set(entry.subjects.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
            let dedupedLanguages = Set(entry.languages.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })

            for author in dedupedAuthors {
                guard let normalized = Self.normalizedTerm(axis: "author", term: author) else { continue }
                weights[TermKey(axis: "author", term: normalized), default: 0] += contribution
            }
            for subject in dedupedSubjects {
                let split = subject.contains(";")
                    ? Self.splitSubjectTokens(subject)
                    : [subject.lowercased().trimmingCharacters(in: .whitespaces)]
                for token in split {
                    guard !token.isEmpty else { continue }
                    guard let normalized = Self.normalizedTerm(axis: "subject", term: token) else { continue }
                    weights[TermKey(axis: "subject", term: normalized), default: 0] += contribution
                }
            }
            for language in dedupedLanguages {
                guard let normalized = Self.normalizedTerm(axis: "language", term: language) else { continue }
                weights[TermKey(axis: "language", term: normalized), default: 0] += contribution
            }
        }

        for seed in OnboardingTasteSeeds.seeds(for: onboardingSelectionIDs) {
            weights[TermKey(axis: seed.axis, term: seed.term.lowercased()), default: 0] += seed.weight
        }

        return weights.map { TermWeight(axis: $0.key.axis, term: $0.key.term, weight: $0.value) }
    }

    public static func buildProfile(
        history: [ListeningHistoryEntry],
        onboardingSelectionIDs: Set<String> = []
    ) -> ProfileBucket {
        let rawTerms = termWeights(history: history, onboardingSelectionIDs: onboardingSelectionIDs)
        return profile(fromRawTerms: rawTerms)
    }

    public static func profile(fromRawTerms rawTerms: [TermWeight]) -> ProfileBucket {
        var authors: [TasteTerm] = []
        var subjects: [TasteTerm] = []
        var languages: [TasteTerm] = []

        let subjectWeights = rawTerms.filter { $0.axis == "subject" }
        let distinctSubjectCount = Set(subjectWeights.map(\.term)).count
        let subjectDampDivisor = distinctSubjectCount > 0
            ? 1.0 + log(Double(distinctSubjectCount) + 1.0)
            : 1.0

        for t in rawTerms {
            var weight = t.weight
            if t.axis == "subject" {
                if Self.isCollectionLikeSubject(t.term) {
                    continue
                }
                if RecommendationConstants.subjectStopList.contains(t.term) {
                    weight *= 0.05
                } else {
                    weight /= subjectDampDivisor
                }
            }
            let term = TasteTerm(axis: t.axis, term: t.term, weight: weight)
            switch t.axis {
            case "author": authors.append(term)
            case "subject": subjects.append(term)
            case "language": languages.append(term)
            default: break
            }
        }

        authors.sort { $0.weight > $1.weight }
        subjects.sort { $0.weight > $1.weight }
        languages.sort { $0.weight > $1.weight }

        return ProfileBucket(
            bucket: "audiobooks",
            creatorTerms: authors,
            subjectTerms: subjects,
            languageTerms: languages
        )
    }

    public static func historyIncrement(forSeconds seconds: Double) -> Double {
        let hours = seconds / 3600.0
        return min(12.0, max(RecommendationConstants.minListenIncrement, hours))
    }

    public static func rank(
        candidates: [InternetArchiveSearchResult],
        profile: ProfileBucket,
        excludeKeys: Set<String> = [],
        k: Int = RecommendationConstants.kTarget,
        lambda: Double = RecommendationConstants.lambdaMMR
    ) -> [InternetArchiveSearchResult] {
        var seen: Set<String> = []
        var filtered: [InternetArchiveSearchResult] = []
        for c in candidates {
            if !c.isStrictLibriVoxCatalogCandidate { continue }
            if isExcluded(c, excludeKeys: excludeKeys) { continue }
            let keys = identityKeys(for: c)
            if seen.isDisjoint(with: keys) {
                seen.formUnion(keys)
                filtered.append(c)
            }
        }

        guard !filtered.isEmpty else { return [] }

        let scored = scoreCandidates(filtered, profile: profile)
        return greedyMMR(scored, k: k, lambda: lambda)
    }

    public static func recommendations(
        history: [ListeningHistoryEntry],
        onboardingSelectionIDs: Set<String>,
        candidates: [InternetArchiveSearchResult],
        excludeKeys: Set<String> = [],
        k: Int = RecommendationConstants.kTarget
    ) -> [InternetArchiveSearchResult] {
        let profile = buildProfile(history: history, onboardingSelectionIDs: onboardingSelectionIDs)

        if profile.isEmpty {
            return filterExcluded(HomeRecommendationStore.bundledPopularSeeds, excludeKeys: excludeKeys)
        }

        let ranked = rank(candidates: candidates, profile: profile, excludeKeys: excludeKeys, k: k)
        if ranked.isEmpty {
            return filterExcluded(HomeRecommendationStore.bundledPopularSeeds, excludeKeys: excludeKeys)
        }
        return ranked
    }

    public static func scoreCandidates(
        _ results: [InternetArchiveSearchResult],
        profile: ProfileBucket
    ) -> [(result: InternetArchiveSearchResult, score: Double)] {
        var profileWeights: [String: Double] = [:]
        for t in profile.allTerms() {
            profileWeights[t.term, default: 0] += t.weight
        }
        let profileNorm = profileWeights.values.reduce(0) { $0 + $1 * $1 }
        let profileNormSqrt = sqrt(profileNorm)

        var scored: [(result: InternetArchiveSearchResult, score: Double)] = []
        for result in results {
            let tokens = extractTokens(result)
            var affinity: Double = 0
            for token in tokens {
                affinity += profileWeights[token] ?? 0
            }
            let tokenNorm = Double(tokens.count)
            if profileNormSqrt > 0, tokenNorm > 0 {
                affinity = affinity / (profileNormSqrt * sqrt(tokenNorm))
            }
            let dl = max(1, result.downloads ?? 1)
            let popPrior = log(1.0 + Double(dl)) / log(Double(RecommendationConstants.downloadFloor))
            let pop = min(1.0, popPrior * 0.5)

            let score = RecommendationConstants.wAffinity * affinity
                      + RecommendationConstants.wPop * pop
            scored.append((result, score))
        }
        return scored.sorted { $0.score > $1.score }
    }

    public static func extractTokens(_ result: InternetArchiveSearchResult) -> [String] {
        var tokens: [String] = []
        for creator in result.creators {
            let c = creator.lowercased().trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, c != "unknown", c != "various", c != "anonymous" {
                tokens.append(c)
            }
        }
        for lang in result.languages {
            let l = lang.lowercased().trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { tokens.append(l) }
        }
        for subject in result.subjects {
            let split = subject.contains(";")
                ? Self.splitSubjectTokens(subject)
                : [subject.lowercased().trimmingCharacters(in: .whitespaces)]
            for s in split {
                guard !s.isEmpty, !RecommendationConstants.subjectStopList.contains(s) else { continue }
                tokens.append(s)
            }
        }
        return Array(Set(tokens))
    }

    public static func greedyMMR(
        _ candidates: [(result: InternetArchiveSearchResult, score: Double)],
        k: Int,
        lambda: Double
    ) -> [InternetArchiveSearchResult] {
        guard !candidates.isEmpty else { return [] }
        var remaining = candidates
        var picked: [InternetArchiveSearchResult] = []
        let targetK = min(k, candidates.count)

        while picked.count < targetK, !remaining.isEmpty {
            var bestIdx = 0
            var bestMMR = -Double.infinity
            for i in remaining.indices {
                let s = remaining[i].score
                let maxSim = picked.isEmpty ? 0.0
                    : picked.map { jaccardSimilarity(remaining[i].result, $0) }.max() ?? 0.0
                let mmr = s - lambda * maxSim
                if mmr > bestMMR { bestMMR = mmr; bestIdx = i }
            }
            picked.append(remaining[bestIdx].result)
            remaining.remove(at: bestIdx)
        }
        return picked
    }

    public static func jaccardSimilarity(_ a: InternetArchiveSearchResult, _ b: InternetArchiveSearchResult) -> Double {
        let tokensA = Set(extractTokens(a))
        let tokensB = Set(extractTokens(b))
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    public static func identityKeys(for result: InternetArchiveSearchResult) -> Set<String> {
        var keys: Set<String> = [result.identifier, "ia:\(result.identifier)"]
        let wk = WorkKey.normalized(author: result.authorLine, title: result.title)
        if wk != result.identifier {
            keys.insert(wk)
        }
        return keys
    }

    public static func filterExcluded(
        _ results: [InternetArchiveSearchResult],
        excludeKeys: Set<String>
    ) -> [InternetArchiveSearchResult] {
        var seen: Set<String> = []
        var filtered: [InternetArchiveSearchResult] = []
        for result in results {
            if isExcluded(result, excludeKeys: excludeKeys) { continue }
            let keys = identityKeys(for: result)
            if seen.isDisjoint(with: keys) {
                seen.formUnion(keys)
                filtered.append(result)
            }
        }
        return filtered
    }

    public static func isExcluded(
        _ result: InternetArchiveSearchResult,
        excludeKeys: Set<String>
    ) -> Bool {
        !excludeKeys.isDisjoint(with: identityKeys(for: result))
    }

    public static func splitSubjectTokens(_ raw: String) -> [String] {
        raw.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private helpers

    private struct TermKey: Hashable {
        let axis: String
        let term: String
    }

    private static let knownCollectionIDs: Set<String> = {
        var ids = Set(LibriVoxBrowseGroup.categories.map(\.id))
        ids.insert("popular-librivox")
        ids.insert("great-books")
        ids.insert("greater-books")
        ids.insert("ancient-greece")
        ids.insert("librivoxaudio")
        return ids
    }()

    public static func isCollectionLikeSubject(_ term: String) -> Bool {
        knownCollectionIDs.contains(term) || term.hasPrefix("lv-")
    }

    public static func normalizedTerm(axis rawAxis: String, term rawTerm: String) -> String? {
        let axis = rawAxis.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let term = rawTerm.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !axis.isEmpty, !term.isEmpty else { return nil }

        switch axis {
        case "author":
            guard term != "unknown", term != "unknown author", term != "various", term != "anonymous" else { return nil }
            return term
        case "subject":
            guard !RecommendationConstants.subjectStopList.contains(term),
                  !isCollectionLikeSubject(term) else { return nil }
            return term
        case "language":
            return term
        default:
            return nil
        }
    }
}
