import Foundation

// MARK: - Manifest entry

public struct CuratedManifestEntry: Decodable, Equatable, Sendable {
    public let rank: Int
    public let title: String
    public let author: String
    public let identifier: String

    public init(rank: Int, title: String, author: String, identifier: String) {
        self.rank = rank
        self.title = title
        self.author = author
        self.identifier = identifier
    }
}

// MARK: - Manifest loader

public enum CuratedManifest {
    public static func load(named name: String, bundle: Bundle) -> [CuratedManifestEntry] {
        let data: Data?
        // SPM resource bundles store files at the root; the Xcode host app may
        // preserve the directory structure. Try both locations.
        if let url = bundle.url(forResource: name, withExtension: "json"),
           let d = try? Data(contentsOf: url) {
            data = d
        } else if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/CuratedLists"),
                  let d = try? Data(contentsOf: url) {
            data = d
        } else {
            return []
        }
        return (try? JSONDecoder().decode([CuratedManifestEntry].self, from: data!)) ?? []
    }

    static func load(named name: String) -> [CuratedManifestEntry] {
        load(named: name, bundle: .module)
    }
}

// MARK: - Pager

public enum CuratedPager {
    public static func slice(
        manifest: [CuratedManifestEntry],
        page: Int,
        size: Int
    ) -> [CuratedManifestEntry] {
        guard page >= 1, size > 0 else { return [] }
        let start = (page - 1) * size
        guard start < manifest.count else { return [] }
        let end = min(start + size, manifest.count)
        return Array(manifest[start..<end])
    }

    public static func order(
        results: [InternetArchiveSearchResult],
        by manifestSlice: [CuratedManifestEntry]
    ) -> [InternetArchiveSearchResult] {
        let rankMap = Dictionary(uniqueKeysWithValues: manifestSlice.map { ($0.identifier, $0.rank) })
        return results
            .filter { rankMap[$0.identifier] != nil }
            .sorted { a, b in
                (rankMap[a.identifier] ?? Int.max) < (rankMap[b.identifier] ?? Int.max)
            }
    }
}
