import Combine
import Foundation

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var results: [InternetArchiveSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isResolvingURL = false
    @Published var catalogError: String?

    private let client: InternetArchiveCatalogClient

    init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
    }

    func searchLibriVox(_ query: String) async {
        await runSearch {
            try await client.searchLibriVox(query: query)
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
                results = try await client.searchAdvanced(query: query)
                return nil
            case .identifier(let identifier):
                let metadata = try await client.metadata(for: identifier)
                if metadata.isCollection {
                    results = try await client.searchCollection(identifier: identifier)
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

    private func runSearch(_ operation: () async throws -> [InternetArchiveSearchResult]) async {
        isSearching = true
        defer { isSearching = false }

        do {
            results = try await operation()
        } catch {
            catalogError = error.localizedDescription
        }
    }
}
