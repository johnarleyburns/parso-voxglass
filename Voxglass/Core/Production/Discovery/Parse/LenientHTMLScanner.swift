import Foundation

/// A dependency-free, lenient HTML scanner (NARRATION_NEEDS_SPEC §3.5) —
/// no third-party HTML parser, per the Studio Spec's ZIP-reader precedent.
/// Used as the fallback when the LibriVox forum Atom feeds are unavailable:
/// extracts topic-title anchors from `viewforum.php` and, for a chosen thread,
/// the first post from `viewtopic.php`.
public struct LenientHTMLScanner: Sendable {
    public init() {}

    /// A forum thread discovered in a topic list.
    public struct ThreadItem: Sendable, Equatable {
        public var topicID: String
        public var title: String
        public var url: URL?

        public init(topicID: String, title: String, url: URL? = nil) {
            self.topicID = topicID
            self.title = title
            self.url = url
        }
    }

    /// Extracts `viewtopic.php?t=<id>` anchors from a phpBB topic list page.
    /// Returns topics in document order, de-duplicated by topic id.
    public func scanTopicLinks(_ html: String, baseURL: URL) -> [ThreadItem] {
        var items: [ThreadItem] = []
        var seen = Set<String>()

        let pattern = "href\\s*=\\s*[\"']([^\"']*viewtopic\\.php\\?[^\"']*t\\s*=\\s*(\\d+)[^\"']*)[\"']"
        let range = NSRange(location: 0, length: (html as NSString).length)
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex?.matches(in: html, options: [], range: range) ?? []

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let idRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            let topicID = String(html[idRange])
            guard !seen.contains(topicID) else { continue }
            seen.insert(topicID)
            let title = linkTitle(for: href, in: html, baseURL: baseURL)
            let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            items.append(ThreadItem(topicID: topicID, title: title, url: url))
        }
        return items
    }

    /// The anchor text following the given href up to its closing `</a>`.
    private func linkTitle(for href: String, in html: String, baseURL: URL) -> String {
        let anchorPattern = "href\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: href))[\"'][^>]*>([\\s\\S]*?)<\\/a>"
        let range = NSRange(location: 0, length: (html as NSString).length)
        if let regex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, options: [], range: range),
           let titleRange = Range(match.range(at: 1), in: html) {
            return stripTags(String(html[titleRange]))
        }
        return ""
    }

    /// Strips HTML tags and decodes common entities — enough for forum titles
    /// and first-post text; garbage degrades to empty, never to an error.
    public func stripTags(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&hellip;", with: "…")
        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the page body looks like a login wall (phpBB `ucp.php?mode=login`
    /// or an in-page login form). L3 MUST yield nothing in this case (G-14).
    public func looksLikeLoginPage(_ html: String, finalURL: URL?) -> Bool {
        let lower = html.lowercased()
        if let path = finalURL?.path.lowercased(),
           path.contains("ucp.php") || path.contains("login") {
            return true
        }
        return lower.contains("ucp.php?mode=login")
            || lower.contains("name=\"login\"")
            || lower.contains("id=\"login\"")
    }
}
