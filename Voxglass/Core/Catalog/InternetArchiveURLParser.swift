import Foundation

enum InternetArchiveURLResource: Equatable, Sendable {
    case advancedSearch(query: String)
    case identifier(String)
}

enum InternetArchiveURLParser {
    static func parse(_ rawValue: String) -> InternetArchiveURLResource? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == "archive.org" || host == "www.archive.org" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if url.lastPathComponent == "advancedsearch.php",
           let query = components?.queryItems?.first(where: { $0.name == "q" })?.value,
           !query.isEmpty {
            return .advancedSearch(query: query)
        }

        if pathComponents.first == "search",
           let query = components?.queryItems?.first(where: { $0.name == "query" || $0.name == "q" })?.value,
           !query.isEmpty {
            return .advancedSearch(query: query)
        }

        if let section = pathComponents.first,
           ["details", "metadata", "download"].contains(section),
           pathComponents.count >= 2 {
            return .identifier(pathComponents[1])
        }

        return nil
    }
}
