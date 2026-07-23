import Foundation

public enum RecommendationShelfSource: String, Equatable, Sendable, Codable {
    case personalized
    case popularColdStart
    case popularFallback
}

public struct RecommendationShelf: Equatable {
    public var results: [InternetArchiveSearchResult]
    public var source: RecommendationShelfSource

    public init(results: [InternetArchiveSearchResult], source: RecommendationShelfSource) {
        self.results = results
        self.source = source
    }
}

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
        selectedLanguages: Set<String>,
        soloOnly: Bool = false
    ) async -> [InternetArchiveSearchResult] {
        await fetchRecommendationShelf(
            selectedCollectionIDs: selectedCollectionIDs,
            selectedLanguages: selectedLanguages,
            soloOnly: soloOnly
        ).results
    }

    public func fetchRecommendationShelf(
        selectedCollectionIDs _: Set<String>,
        selectedLanguages: Set<String>,
        soloOnly: Bool = false
    ) async -> RecommendationShelf {
        let languageClause = LibriVoxLanguage.clause(for: selectedLanguages)
        let excludeKeys = await buildExcludeKeys()
        let soloMultiplier = soloOnly ? 2 : 1
        let shelfTarget = 18

        let profile = await profileStore.fetchProfile()
        guard !profile.isEmpty else {
            let coldResults = RecommendationPipeline.filterExcluded(
                HomeRecommendationStore.bundledPopularSeeds,
                excludeKeys: excludeKeys
            )
            let finalResults = soloOnly
                ? coldResults.filter { $0.narrationKind == .solo }
                : coldResults
            return RecommendationShelf(
                results: Array(finalResults.prefix(shelfTarget)),
                source: .popularColdStart
            )
        }

        let popularFallback = {
            let fbResults = RecommendationPipeline.filterExcluded(
                HomeRecommendationStore.bundledPopularSeeds,
                excludeKeys: excludeKeys
            )
            let finalResults = soloOnly
                ? fbResults.filter { $0.narrationKind == .solo }
                : fbResults
            return RecommendationShelf(
                results: finalResults,
                source: RecommendationShelfSource.popularFallback
            )
        }

        let dateSeed = dateSeedString()
        let queries = RecommendationQueryBuilder.generateQueries(
            profile: profile,
            dateSeed: dateSeed,
            languageClause: languageClause
        )
        guard !queries.isEmpty else {
            return popularFallback()
        }

        var candidates: [InternetArchiveSearchResult] = []
        for query in queries.prefix(6) {
            do {
                let rows = query.requestedCount * soloMultiplier
                let results = try await withTimeout(15) { [client] in
                    try await client.searchAdvanced(query: query.iaQuery, rows: rows)
                }
                candidates.append(contentsOf: results)
            } catch {
                continue
            }
        }

        var filtered = RecommendationPipeline.rank(
            candidates: candidates,
            profile: profile,
            excludeKeys: excludeKeys
        )
        var effectiveCandidates = candidates

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
            let combined = candidates + extra
            effectiveCandidates = combined
            filtered = RecommendationPipeline.rank(
                candidates: combined,
                profile: profile,
                excludeKeys: excludeKeys
            )
        }

        guard !filtered.isEmpty else {
            let surfacedIds = await profileStore.fetchSurfacedIdentifiers()
            var excludeMinusSurfaced = excludeKeys
            excludeMinusSurfaced.subtract(surfacedIds)
            let fallbackRanked = RecommendationPipeline.rank(
                candidates: effectiveCandidates,
                profile: profile,
                excludeKeys: excludeMinusSurfaced
            )
            guard !fallbackRanked.isEmpty else {
                return popularFallback()
            }
            let soloFilteredFallback = soloOnly
                ? fallbackRanked.filter { $0.narrationKind == .solo }
                : fallbackRanked
            let shelfSlice = Array(soloFilteredFallback.prefix(18))
            let shelfKeys = shelfSlice.flatMap { Array(RecommendationPipeline.identityKeys(for: $0)) }
            await profileStore.pushSurfaced(shelfKeys)
            return RecommendationShelf(results: shelfSlice, source: .personalized)
        }

        let soloFiltered = soloOnly
            ? filtered.filter { $0.narrationKind == .solo }
            : filtered
        let shelfSlice = Array(soloFiltered.prefix(18))
        let shelfKeys = shelfSlice.flatMap { Array(RecommendationPipeline.identityKeys(for: $0)) }
        await profileStore.pushSurfaced(shelfKeys)

        return RecommendationShelf(results: shelfSlice, source: .personalized)
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
