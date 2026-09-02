import Foundation

/// Best-effort extraction of narrator names from free-form metadata text
/// (typically an Internet Archive / LibriVox item description or summary).
///
/// Recognizes phrasings such as:
///   "Read by Jane Doe"
///   "Narrated by Jane Doe and John Smith"
///   "Narrator: Jane Doe, John Smith"
///   "Reader: Jane Doe"
public enum NarratorExtractor {

    private static let patterns: [String] = [
        #"(?:read(?:\s+in\s+[^\.\n\r;|]+?)?|narrated|voiced|performed)\s+by\s*[:\-]?\s*([^\n\r|]+)"#,
        #"(?:narrators?|readers?)\s*[:\-]\s*([^\.\n\r|]+)"#
    ]

    public static func extract(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }

        var seen: Set<String> = []
        var ordered: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: text) else { continue }
                for name in splitNames(narratorSegment(String(text[captureRange]))) {
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
        let separators = CharacterSet(charactersIn: ",&/;")
        return raw
            .replacingOccurrences(of: #"\band\b"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-"))) }
            .filter { isPlausibleName($0) }
    }

    /// LibriVox descriptions often omit punctuation after the reader credit:
    /// "Read in English by Expatriate Also known as …". Keep the credit from
    /// swallowing the summary that follows it.
    private static func narratorSegment(_ raw: String) -> String {
        let sentenceSafeRaw: String
        if raw.contains(";") {
            // Semicolons are the LibriVox reader-list separator. A period in
            // "Mike T.;" is part of the reader credit, not its boundary.
            sentenceSafeRaw = raw
        } else if let end = raw.firstIndex(of: ".") {
            sentenceSafeRaw = String(raw[..<end])
        } else {
            sentenceSafeRaw = raw
        }
        let boundaries = [
            " For further information", " - Summary by", " Summary by",
            " Also known as", " Fascinated as", " This ", " The ",
            " A ", " An ", " Although ", " When ", " It ", " From ", " As "
        ]
        let ranges = boundaries.compactMap { boundary in
            sentenceSafeRaw.range(of: boundary, options: [.caseInsensitive])?.lowerBound
        }
        guard let end = ranges.min() else { return sentenceSafeRaw }
        return String(sentenceSafeRaw[..<end])
    }

    private static func isPlausibleName(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 60 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        let lowered = value.lowercased()
        let rejected: Set<String> = ["various", "unknown", "anonymous", "n/a", "none", "the"]
        return !rejected.contains(lowered)
    }
}
