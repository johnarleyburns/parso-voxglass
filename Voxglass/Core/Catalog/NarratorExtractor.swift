import Foundation
import os

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
        // Do not let a LibriVox role sheet consume every character credit
        // after the first one. Those descriptions commonly look like:
        // "Read by StephenC AEGISTHUS, cousin ..., read by mb ORESTES ...".
        // Matching lazily through the next credit gives each reader a chance
        // to be normalized independently.
        #"(?:read(?:\s+in\s+[^\.\n\r;|]+?)?|narrated|voiced|performed)\s+by\s*[:\-]?\s*([^\n\r|]+?)(?=(?:\b(?:read|narrated|voiced|performed)\s+by\b)|$)"#,
        #"(?:narrators?|readers?)\s*[:\-]\s*([^\.\n\r|]+)"#
    ]

    /// Compiled once. Discover and Search rows call `extract` on every SwiftUI
    /// body pass, so per-call compilation showed up as main-thread lag.
    private static let regexes: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    private static let andSeparator = try? NSRegularExpression(pattern: #"\band\b"#, options: [.caseInsensitive])

    // In dramatic-reading metadata, a role name is often uppercased and
    // followed by its description. It is not part of the reader's name:
    // "David O'Connell CLYTEMNESTRA, wife of Agamemnon".
    private static let roleBoundary = try? NSRegularExpression(
        pattern: #"\s+[A-Z][A-Z0-9'’.-]{2,}\s*,\s*(?i:cousin|son|daughter|wife|husband|mother|father|brother|sister|king|queen|servant|messenger)\b"#
    )
    private static let roleAtEnd = try? NSRegularExpression(
        pattern: #"\s+[A-Z][A-Z0-9'’.-]{2,}\s*$"#
    )

    /// Recent results keyed by the source text. Rows re-render many times while
    /// covers and counts load; after the first pass each lookup is a hash hit.
    private static let cache = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])
    private static let cacheLimit = 1_024

    public static func extract(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        if let cached = cache.withLock({ $0[text] }) { return cached }
        let names = uncachedExtract(from: text)
        cache.withLock { cache in
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[text] = names
        }
        return names
    }

    private static func uncachedExtract(from text: String) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        let hasRoleSheet = text.range(of: #"\bread\s+by\b.*\bread\s+by\b"#, options: [.regularExpression, .caseInsensitive]) != nil

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in regexes {
            for match in regex.matches(in: text, options: [], range: range) {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: text) else { continue }
                let rawSegment = String(text[captureRange])
                let segment = narratorSegment(trimRoleMetadata(rawSegment, hasRoleSheet: hasRoleSheet))
                for name in splitNames(segment) {
                    if seen.insert(name.lowercased()).inserted {
                        ordered.append(name)
                    }
                }
            }
            if !ordered.isEmpty { break }
        }

        return ordered
    }

    private static func trimRoleMetadata(_ raw: String, hasRoleSheet: Bool) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        if let roleBoundary,
           let match = roleBoundary.firstMatch(in: raw, options: [], range: range),
           let boundary = Range(match.range, in: raw) {
            return String(raw[..<boundary.lowerBound])
        }

        // The last role in a sheet may omit its prose description. Only apply
        // this fallback when the complete description already proved that it
        // contains several role credits; ordinary names such as "PETER
        // YEARSLEY" must remain untouched.
        if hasRoleSheet,
           let roleAtEnd,
           let match = roleAtEnd.firstMatch(in: raw, options: [], range: range),
           let boundary = Range(match.range, in: raw) {
            return String(raw[..<boundary.lowerBound])
        }
        return raw
    }

    private static func splitNames(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",&/;")
        let commaSeparated: String
        if let andSeparator {
            commaSeparated = andSeparator.stringByReplacingMatches(
                in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw), withTemplate: ",")
        } else {
            commaSeparated = raw
        }
        return commaSeparated
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
        // NSString search: `String.range(of:options: .caseInsensitive)` costs
        // ~0.5 ms per call here, ~100× more, and this runs 14 times per row.
        let nsRaw = sentenceSafeRaw as NSString
        let ends = segmentBoundaries
            .map { nsRaw.range(of: $0, options: .caseInsensitive).location }
            .filter { $0 != NSNotFound }
        guard let end = ends.min() else { return sentenceSafeRaw }
        return nsRaw.substring(to: end)
    }

    /// Phrases that start the item summary after an unpunctuated reader credit.
    private static let segmentBoundaries = [
        " For further information", " - Summary by", " Summary by",
        " Also known as", " Fascinated as", " This ", " The ",
        " A ", " An ", " Although ", " When ", " It ", " From ", " As "
    ]

    private static let rejectedNames: Set<String> = ["various", "unknown", "anonymous", "n/a", "none", "the"]

    private static func isPlausibleName(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 60 else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        let lowered = value.lowercased()
        return !rejectedNames.contains(lowered)
    }
}
