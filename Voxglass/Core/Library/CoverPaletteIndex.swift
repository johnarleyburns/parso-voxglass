import CryptoKit
import Foundation

/// Computes the stable palette slot for a book's typographic cover.
public enum CoverPaletteIndex {
    /// Returns the first SHA-256 byte of normalized title and author modulo count.
    public static func index(title: String, author: String?, count: Int = 8) -> Int {
        guard count > 0 else { return 0 }
        let input = normalize(title) + "\u{1F}" + normalize(author ?? "")
        let digest = Array(SHA256.hash(data: Data(input.utf8)))
        return Int(digest.first ?? 0) % count
    }

    private static func normalize(_ value: String) -> String {
        var result = value.precomposedStringWithCompatibilityMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        for article in ["the ", "a ", "an "] where result.hasPrefix(article) {
            result.removeFirst(article.count)
            break
        }
        return result
    }
}
