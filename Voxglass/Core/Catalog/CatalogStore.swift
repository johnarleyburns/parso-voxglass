import Combine
import Foundation

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var results: [InternetArchiveSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isResolvingURL = false
    @Published private(set) var hasMore = false
    @Published var catalogError: String?

    /// The user's search text, promoted to the store so it survives `SearchView`
    /// being recreated on tab changes (§3). `SearchView` binds its field to this.
    @Published var query: String = ""

    /// Languages the user has selected (see §1). Kept in sync from
    /// `AppPreferencesStore`; injected centrally into every catalog query so
    /// language filtering is applied in exactly one place.
    var selectedLanguages: Set<String> = LibriVoxLanguage.defaultSelection {
        didSet {
            guard oldValue != selectedLanguages else { return }
            reloadForLanguageChange()
        }
    }

    private let client: InternetArchiveCatalogClient
    private let pageSize = 25
    private var activeQuery: String?
    private var currentPage = 1
    private var numFound = 0
    private var seenIdentifiers: Set<String> = []

    init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
    }

    private var languageClause: String {
        LibriVoxLanguage.clause(for: selectedLanguages)
    }

    func searchLibriVox(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        guard !trimmed.isEmpty else {
            resetResults()
            return
        }
        await runSearch(query: InternetArchiveClient.libriVoxQuery(for: trimmed) + languageClause)
    }

    func searchAdvanced(_ query: String) async {
        await runSearch(query: query + languageClause)
    }

    func loadMore() async {
        guard hasMore, !isSearching, !isLoadingMore, let query = activeQuery else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        do {
            let page = try await client.searchAdvancedPage(query: query, rows: pageSize, page: nextPage)
            currentPage = nextPage
            numFound = page.numFound
            let appended = page.results.filter { seenIdentifiers.insert($0.identifier).inserted }
            results.append(contentsOf: appended)
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    func importResult(
        _ result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        do {
            let metadata = try await client.metadata(for: result.identifier)
            return await libraryStore.importInternetArchiveItem(metadata, sourceKind: result.sourceKind)
        } catch {
            // A seed identifier can go stale (archive.org returns an empty body).
            // Rather than dead-end the tap, search LibriVox for the same work by
            // title + creator and import the top live match. This keeps any future
            // stale bundled/recommended seed playable.
            if let recovered = await importBySearchFallback(for: result, into: libraryStore) {
                return recovered
            }
            catalogError = Self.importErrorMessage(for: result, underlying: error)
            return nil
        }
    }

    /// Recovers a stale seed by searching for a live item with the same title and
    /// creator, then importing the first result that actually resolves.
    private func importBySearchFallback(
        for result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        let query = Self.recoveryQuery(for: result)
        guard let query else { return nil }

        let candidates = (try? await client.searchAdvanced(query: query, rows: 5)) ?? []
        for candidate in candidates where candidate.identifier != result.identifier {
            guard let metadata = try? await client.metadata(for: candidate.identifier) else {
                continue
            }
            if let imported = await libraryStore.importInternetArchiveItem(metadata, sourceKind: candidate.sourceKind) {
                return imported
            }
        }
        return nil
    }

    /// Builds a precise `title + creator` LibriVox query for seed recovery, or
    /// `nil` when there is no title to anchor on.
    private static func recoveryQuery(for result: InternetArchiveSearchResult) -> String? {
        let title = escapeSolrPhrase(result.title)
        guard !title.isEmpty else { return nil }

        var clauses = ["title:\"\(title)\""]
        if let creator = result.creators.first.map(escapeSolrPhrase), !creator.isEmpty {
            clauses.append("creator:\"\(creator)\"")
        }
        clauses.append("collection:librivoxaudio")
        clauses.append("mediatype:audio")
        return clauses.joined(separator: " AND ")
    }

    private static func escapeSolrPhrase(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func importErrorMessage(
        for result: InternetArchiveSearchResult,
        underlying error: Error
    ) -> String {
        "Couldn't load '\(result.title)' (\(result.identifier)): \(error.localizedDescription)"
    }

    func addArchiveURL(
        _ rawValue: String,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        guard let resource = InternetArchiveURLParser.parse(rawValue) else {
            catalogError = InternetArchiveError.unsupportedURL.localizedDescription
            return nil
        }

        isResolvingURL = true
        defer { isResolvingURL = false }

        do {
            switch resource {
            case .advancedSearch(let query):
                await runSearch(query: query + languageClause)
                return nil
            case .identifier(let identifier):
                let metadata = try await client.metadata(for: identifier)
                if metadata.isCollection {
                    results = try await client.searchCollection(identifier: identifier)
                    resetPaging()
                    return nil
                }

                let sourceKind: SourceKind = metadata.sourceKind == .librivox ? .librivox : .internetArchiveURL
                return await libraryStore.importInternetArchiveItem(metadata, sourceKind: sourceKind)
            }
        } catch {
            catalogError = error.localizedDescription
            return nil
        }
    }

    private func runSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }

        activeQuery = query
        currentPage = 1

        do {
            let page = try await client.searchAdvancedPage(query: query, rows: pageSize, page: 1)
            numFound = page.numFound
            seenIdentifiers = []
            results = page.results.filter { seenIdentifiers.insert($0.identifier).inserted }
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func reloadForLanguageChange() {
        guard let base = baseQuery(from: activeQuery) else { return }
        Task { await runSearch(query: base + languageClause) }
    }

    /// Strips a previously-appended language clause so the base query can be
    /// re-decorated when the selection changes.
    private func baseQuery(from query: String?) -> String? {
        guard let query else { return nil }
        guard let range = query.range(of: " AND (language:") else { return query }
        return String(query[query.startIndex..<range.lowerBound])
    }

    private func resetResults() {
        results = []
        query = ""
        resetPaging()
    }

    private func resetPaging() {
        activeQuery = nil
        currentPage = 1
        numFound = 0
        hasMore = false
        seenIdentifiers = Set(results.map(\.identifier))
    }

    private func updateHasMore() {
        hasMore = results.count < numFound && !results.isEmpty
    }
}
