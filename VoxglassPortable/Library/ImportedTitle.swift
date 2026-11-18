import Foundation

/// The presentation-only title/author fallback for local imports.
public struct ImportedTitle: Equatable, Sendable {
    public let title: String
    public let author: String?

    public init(title: String, author: String?) {
        self.title = title
        self.author = author
    }
}

/// Parses common local audiobook filename conventions without changing stored metadata.
public enum ImportedTitles {
    public static func parse(_ input: String) -> ImportedTitle {
        let cleaned = stripSuffixes(input.trimmingCharacters(in: .whitespacesAndNewlines))
        let separators = [" - ", " – ", " — "]
        guard let separator = separators.first(where: { cleaned.contains($0) }) else {
            return ImportedTitle(title: cleaned, author: nil)
        }
        let parts = cleaned.components(separatedBy: separator)
        guard parts.count == 2 else { return ImportedTitle(title: cleaned, author: nil) }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        let leftIsAuthor = isLikelyAuthor(left)
        let rightIsAuthor = isLikelyAuthor(right)
        switch (leftIsAuthor, rightIsAuthor) {
        case (false, true): return ImportedTitle(title: left, author: right)
        case (true, false): return ImportedTitle(title: right, author: left)
        case (true, true): return ImportedTitle(title: left, author: right)
        default: return ImportedTitle(title: cleaned, author: nil)
        }
    }

    private static func stripSuffixes(_ input: String) -> String {
        var value = input
        let suffixes = ["(unabridged)", "[audiobook]", " audiobook", " audio book"]
        for suffix in suffixes where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyAuthor(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0.isWhitespace })
        guard (2...4).contains(words.count), !value.contains(where: { $0.isNumber }) else { return false }
        let particles = Set(["de", "van", "von", "da", "del", "di", "le", "la"])
        return words.allSatisfy { word in
            let token = String(word)
            return particles.contains(token.lowercased()) || token.first?.isUppercase == true
        }
    }
}
