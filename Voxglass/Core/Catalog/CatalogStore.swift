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
            catalogError = error.localizedDescription
            return nil
        }
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
