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
        selectedLanguages: Set<String>
    ) async -> [InternetArchiveSearchResult] {
        await fetchRecommendationShelf(
            selectedCollectionIDs: selectedCollectionIDs,
            selectedLanguages: selectedLanguages
        ).results
    }

    public func fetchRecommendationShelf(
        selectedCollectionIDs _: Set<String>,
        selectedLanguages: Set<String>
    ) async -> RecommendationShelf {
        let languageClause = LibriVoxLanguage.clause(for: selectedLanguages)
        let excludeKeys = await buildExcludeKeys()

        let profile = await profileStore.fetchProfile()
        guard !profile.isEmpty else {
            return RecommendationShelf(
                results: RecommendationPipeline.filterExcluded(
                    HomeRecommendationStore.bundledPopularSeeds,
                    excludeKeys: excludeKeys
                ),
                source: .popularColdStart
            )
        }

        let popularFallback = {
            RecommendationShelf(
                results: RecommendationPipeline.filterExcluded(
                    HomeRecommendationStore.bundledPopularSeeds,
                    excludeKeys: excludeKeys
                ),
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
                let results = try await withTimeout(15) { [client] in
                    try await client.searchAdvanced(query: query.iaQuery, rows: query.requestedCount)
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
            filtered = RecommendationPipeline.rank(
                candidates: combined,
                profile: profile,
                excludeKeys: excludeKeys
            )
        }

        guard !filtered.isEmpty else {
            return popularFallback()
        }

        let surfacedKeys = filtered.flatMap { Array(RecommendationPipeline.identityKeys(for: $0)) }
        await profileStore.pushSurfaced(surfacedKeys)

        return RecommendationShelf(results: Array(filtered.prefix(18)), source: .personalized)
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
