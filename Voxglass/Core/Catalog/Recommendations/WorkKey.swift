import Foundation

public enum WorkKey {

    public static func normalized(author: String, title: String) -> String {
        let normalizedAuthor = author.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let cleaned = cleanTitle(title)
        return "\(normalizedAuthor)\u{00B7}\(cleaned)"
    }

    public static func cleanTitle(_ raw: String) -> String {
        var t = raw
        let patterns: [String] = [
            #"\(version\s*\d+\)"#,
            #"\(dramatic reading\)"#,
            #"\(read by [^)]+\)"#,
            #"\(solo\)"#,
            #"\(group\)"#,
            #"\(in [^)]+\)"#,
            #"\(unabridged\)"#,
            #"\(abridged\)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: [.caseInsensitive]) {
                t = regex.stringByReplacingMatches(in: t,
                    range: NSRange(location: 0, length: t.utf16.count),
                    withTemplate: "")
            }
        }
        t = t.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return t
    }
}
