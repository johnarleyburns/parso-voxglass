import Foundation

@MainActor
public final class RecommendationEngine {
    private let client: InternetArchiveCatalogClient
    private let profileStore: TasteProfileStore
    private let libraryStore: LibraryStore

    public init(
        client: InternetArchiveCatalogClient = InternetArchiveClient(),
        profileStore: TasteProfileStore,
        libraryStore: LibraryStore
    ) {
        self.client = client
        self.profileStore = profileStore
        self.libraryStore = libraryStore
    }

    public func fetchRecommendations(
        selectedCollectionIDs: Set<String>,
        selectedLanguages: Set<String>
    ) async -> [InternetArchiveSearchResult] {
        let languageClause = LibriVoxLanguage.clause(for: selectedLanguages)
        let excludeKeys = await buildExcludeKeys()
        let hasProfile = await profileStore.hasProfile()

        if !hasProfile {
            let onboarded = HomeRecommendationStore.coldStartRecommendations(for: selectedCollectionIDs)
            await profileStore.seedOnboardingPicks(from: selectedCollectionIDs)
            return filterExcluded(onboarded, excludeKeys: excludeKeys)
        }

        let profile = await profileStore.fetchProfile()
        guard !profile.isEmpty else {
            return filterExcluded(
                HomeRecommendationStore.coldStartRecommendations(for: selectedCollectionIDs),
                excludeKeys: excludeKeys
            )
        }

        let dateSeed = dateSeedString()
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: dateSeed,
            languageClause: languageClause
        )
        guard !queries.isEmpty else {
            return bundledFallback(selectedCollectionIDs: selectedCollectionIDs, excludeKeys: excludeKeys)
        }

        var candidates: [InternetArchiveSearchResult] = []
        for query in queries.prefix(6) {
            do {
                let results = try await withTimeout(15) { [client] in
                    try await client.searchAdvanced(query: query.iaQuery, rows: query.requestedCount)
                }
                candidates.append(contentsOf: results)
            } catch {
                continue
            }
        }

        var seen: Set<String> = []
        var filtered: [InternetArchiveSearchResult] = []
        for c in candidates {
            if excluded(c, excludeKeys: excludeKeys) { continue }
            let keys = identityKeys(for: c)
            if seen.isDisjoint(with: keys) {
                seen.formUnion(keys)
                filtered.append(c)
            }
        }

        if filtered.count < RecommendationConstants.minShelf {
            let fallbackQueries = buildFallbackQueries(profile: profile, languageClause: languageClause)
            var extra: [InternetArchiveSearchResult] = []
            for query in fallbackQueries {
                do {
                    let results = try await withTimeout(15) { [client] in
                        try await client.searchAdvanced(query: query, rows: 10)
                    }
                    extra.append(contentsOf: results)
                } catch {
                    continue
                }
            }
            for c in extra {
                if excluded(c, excludeKeys: excludeKeys) { continue }
                let keys = identityKeys(for: c)
                if seen.isDisjoint(with: keys) {
                    seen.formUnion(keys)
                    filtered.append(c)
                }
            }
        }

        guard !filtered.isEmpty else {
            return bundledFallback(selectedCollectionIDs: selectedCollectionIDs, excludeKeys: excludeKeys)
        }

        let scored = scoreCandidates(filtered, profile: profile)
        let topK = greedyMMR(scored, k: RecommendationConstants.kTarget,
                             lambda: RecommendationConstants.lambdaMMR)

        let surfacedKeys = topK.flatMap { Array(identityKeys(for: $0)) }
        await profileStore.pushSurfaced(surfacedKeys)

        return Array(topK.prefix(18))
    }

    // MARK: - Private

    private func dateSeedString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func buildExcludeKeys() async -> Set<String> {
        let surfacedIds = await profileStore.fetchSurfacedIdentifiers()
        let listenedKeys = await libraryStore.refreshListenedWorkExclusionKeys()
        let libraryWorkKeys = Set(libraryStore.books.map { book in
            WorkKey.normalized(author: book.book.authorLine, title: book.book.title)
        })
        let libraryRawIDs = Set(libraryStore.books.map(\.book.id.uuidString))
        return surfacedIds.union(listenedKeys).union(libraryWorkKeys).union(libraryRawIDs)
    }

    private func filterExcluded(
        _ results: [InternetArchiveSearchResult],
        excludeKeys: Set<String>
    ) -> [InternetArchiveSearchResult] {
        var seen: Set<String> = []
        var filtered: [InternetArchiveSearchResult] = []
        for result in results {
            if excluded(result, excludeKeys: excludeKeys) { continue }
            let keys = identityKeys(for: result)
            if seen.isDisjoint(with: keys) {
                seen.formUnion(keys)
                filtered.append(result)
            }
        }
        return filtered
    }

    private func bundledFallback(
        selectedCollectionIDs: Set<String>,
        excludeKeys: Set<String>
    ) -> [InternetArchiveSearchResult] {
        filterExcluded(
            HomeRecommendationStore.coldStartRecommendations(for: selectedCollectionIDs),
            excludeKeys: excludeKeys
        )
    }

    private func excluded(_ result: InternetArchiveSearchResult, excludeKeys: Set<String>) -> Bool {
        !excludeKeys.isDisjoint(with: identityKeys(for: result))
    }

    private func identityKeys(for result: InternetArchiveSearchResult) -> Set<String> {
        var keys: Set<String> = [result.identifier, "ia:\(result.identifier)"]
        let wk = WorkKey.normalized(author: result.authorLine, title: result.title)
        if wk != result.identifier {
            keys.insert(wk)
        }
        return keys
    }

    private func scoreCandidates(_ results: [InternetArchiveSearchResult],
                                  profile: ProfileBucket) -> [(result: InternetArchiveSearchResult, score: Double)] {
        Self.scoreCandidates(results, profile: profile)
    }

    nonisolated static func scoreCandidates(_ results: [InternetArchiveSearchResult],
                                            profile: ProfileBucket) -> [(result: InternetArchiveSearchResult, score: Double)] {
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

    nonisolated static func extractTokens(_ result: InternetArchiveSearchResult) -> [String] {
        var tokens: [String] = []
        for creator in result.creators {
            let c = creator.lowercased().trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, c != "unknown", c != "various" {
                tokens.append(c)
            }
        }
        for lang in result.languages {
            let l = lang.lowercased().trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { tokens.append(l) }
        }
        for subject in result.subjects {
            let s = subject.lowercased().trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, !RecommendationConstants.subjectStopList.contains(s) {
                tokens.append(s)
            }
        }
        return Array(Set(tokens))
    }

    private func greedyMMR(_ candidates: [(result: InternetArchiveSearchResult, score: Double)],
                            k: Int, lambda: Double) -> [InternetArchiveSearchResult] {
        Self.greedyMMR(candidates, k: k, lambda: lambda)
    }

    nonisolated static func greedyMMR(_ candidates: [(result: InternetArchiveSearchResult, score: Double)],
                                      k: Int, lambda: Double) -> [InternetArchiveSearchResult] {
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

    nonisolated static func jaccardSimilarity(_ a: InternetArchiveSearchResult, _ b: InternetArchiveSearchResult) -> Double {
        let tokensA = Set(extractTokens(a))
        let tokensB = Set(extractTokens(b))
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func buildFallbackQueries(profile: ProfileBucket,
                                       languageClause: String) -> [String] {
        let scopeClause = " AND \(LibriVoxCatalogScope.query)" + (languageClause.isEmpty ? "" : " \(languageClause)")
        var queries: [String] = []

        for creator in profile.topCreators.prefix(5) {
            queries.append("creator:\"\(creator.replacingOccurrences(of: "\"", with: ""))\"\(scopeClause)")
        }
        for subject in profile.topSubjects.prefix(5) {
            queries.append("subject:\"\(subject.replacingOccurrences(of: "\"", with: ""))\"\(scopeClause)")
        }
        return Array(Set(queries)).shuffled()
    }

    private func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}
