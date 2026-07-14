import Foundation

/// Best-effort extraction of narrator names from free-form metadata text
/// (typically an Internet Archive / LibriVox item description or summary).
///
/// Recognizes phrasings such as:
///   "Read by Jane Doe"
///   "Narrated by Jane Doe and John Smith"
///   "Narrator: Jane Doe, John Smith"
///   "Reader: Jane Doe"
enum NarratorExtractor {

    private static let patterns: [String] = [
        #"(?:read|narrated|voiced|performed)\s+by\s*[:\-]?\s*([^\.\n\r;|]+)"#,
        #"(?:narrators?|readers?)\s*[:\-]\s*([^\.\n\r;|]+)"#
    ]

    static func extract(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }

        var seen: Set<String> = []
        var ordered: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: text) else { continue }
                for name in splitNames(String(text[captureRange])) {
                    if seen.insert(name.lowercased()).inserted {
                        ordered.append(name)
                    }
                }
            }
            if !ordered.isEmpty { break }
        }

        return ordered
    }

    private static func splitNames(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",&/")
        return raw
            .replacingOccurrences(of: #"\band\b"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-"))) }
            .filter { isPlausibleName($0) }
    }

    private static func isPlausibleName(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 60 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        let lowered = value.lowercased()
        let rejected: Set<String> = ["various", "unknown", "anonymous", "n/a", "none", "the"]
        return !rejected.contains(lowered)
    }
}
