import Foundation

/// A curated list of the most common LibriVox languages on the Internet Archive.
///
/// The `archive.org` `language` field is inconsistent (ISO codes vs. full names),
/// so each entry ORs the accepted forms. Tokens were verified against live
/// `collection:librivoxaudio AND language:<token>` counts — LibriVox items are
/// overwhelmingly indexed with ISO 639-2/B or 639-3 codes (e.g. `eng`, `deu`,
/// `fre`/`fra`, `grc`).
public struct LibriVoxLanguage: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var tokens: [String]

    public var clause: String {
        tokens.map { "language:\($0)" }.joined(separator: " OR ")
    }

    public static let all: [LibriVoxLanguage] = [
        LibriVoxLanguage(id: "eng", displayName: "English", tokens: ["eng", "English"]),
        LibriVoxLanguage(id: "deu", displayName: "German", tokens: ["deu", "ger", "German"]),
        LibriVoxLanguage(id: "fre", displayName: "French", tokens: ["fre", "fra", "French"]),
        LibriVoxLanguage(id: "nld", displayName: "Dutch", tokens: ["nld", "dut", "Dutch"]),
        LibriVoxLanguage(id: "spa", displayName: "Spanish", tokens: ["spa", "Spanish"]),
        LibriVoxLanguage(id: "ita", displayName: "Italian", tokens: ["ita", "Italian"]),
        LibriVoxLanguage(id: "por", displayName: "Portuguese", tokens: ["por", "Portuguese"]),
        LibriVoxLanguage(id: "rus", displayName: "Russian", tokens: ["rus", "Russian"]),
        LibriVoxLanguage(id: "zho", displayName: "Chinese", tokens: ["zho", "chi", "Chinese"]),
        LibriVoxLanguage(id: "jpn", displayName: "Japanese", tokens: ["jpn", "Japanese"]),
        LibriVoxLanguage(id: "lat", displayName: "Latin", tokens: ["lat", "Latin"]),
        LibriVoxLanguage(id: "grc", displayName: "Greek", tokens: ["grc", "gre", "Greek"]),
        LibriVoxLanguage(id: "pol", displayName: "Polish", tokens: ["pol", "Polish"]),
        LibriVoxLanguage(id: "fin", displayName: "Finnish", tokens: ["fin", "Finnish"]),
        LibriVoxLanguage(id: "heb", displayName: "Hebrew", tokens: ["heb", "Hebrew"])
    ]

    public static let defaultSelection: Set<String> = ["eng"]

    public static func language(withID id: String) -> LibriVoxLanguage? {
        all.first { $0.id == id }
    }

    /// Builds a query fragment restricting results to the selected languages,
    /// e.g. `" AND (language:eng OR language:English OR language:deu OR ...)"`.
    /// Returns `""` when the set is empty (interpreted as "all languages"),
    /// leaving the delegated query unfiltered.
    public static func clause(for codes: Set<String>) -> String {
        let selected = all.filter { codes.contains($0.id) }
        guard !selected.isEmpty else { return "" }
        let joined = selected.map(\.clause).joined(separator: " OR ")
        return " AND (\(joined))"
    }
}
