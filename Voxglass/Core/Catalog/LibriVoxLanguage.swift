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
    private var englishName: String
    public var tokens: [String]

    public var displayName: String {
        if englishName == "German" {
            return String(localized: "German", bundle: .module)
        }
        return Locale.current.localizedString(forLanguageCode: id) ?? englishName
    }

    public var clause: String {
        tokens.map { "language:\($0)" }.joined(separator: " OR ")
    }

    public static let all: [LibriVoxLanguage] = [
        LibriVoxLanguage(id: "eng", englishName: "English", tokens: ["eng", "English"]),
        LibriVoxLanguage(id: "deu", englishName: "German", tokens: ["deu", "ger", "German"]),
        LibriVoxLanguage(id: "fre", englishName: "French", tokens: ["fre", "fra", "French"]),
        LibriVoxLanguage(id: "nld", englishName: "Dutch", tokens: ["nld", "dut", "Dutch"]),
        LibriVoxLanguage(id: "spa", englishName: "Spanish", tokens: ["spa", "Spanish"]),
        LibriVoxLanguage(id: "ita", englishName: "Italian", tokens: ["ita", "Italian"]),
        LibriVoxLanguage(id: "por", englishName: "Portuguese", tokens: ["por", "Portuguese"]),
        LibriVoxLanguage(id: "rus", englishName: "Russian", tokens: ["rus", "Russian"]),
        LibriVoxLanguage(id: "zho", englishName: "Chinese", tokens: ["zho", "chi", "Chinese"]),
        LibriVoxLanguage(id: "jpn", englishName: "Japanese", tokens: ["jpn", "Japanese"]),
        LibriVoxLanguage(id: "lat", englishName: "Latin", tokens: ["lat", "Latin"]),
        LibriVoxLanguage(id: "grc", englishName: "Greek", tokens: ["grc", "gre", "Greek"]),
        LibriVoxLanguage(id: "pol", englishName: "Polish", tokens: ["pol", "Polish"]),
        LibriVoxLanguage(id: "fin", englishName: "Finnish", tokens: ["fin", "Finnish"]),
        LibriVoxLanguage(id: "heb", englishName: "Hebrew", tokens: ["heb", "Hebrew"])
    ]

    public static var defaultSelection: Set<String> { deviceDefaultSelection() }

    /// Default language selection for a new install, retaining English while
    /// adding the device's supported primary language when available.
    public static func deviceDefaultSelection(preferredLanguages: [String] = Locale.preferredLanguages) -> Set<String> {
        var result: Set<String> = ["eng"]
        for tag in preferredLanguages {
            let primary = tag.lowercased().split(separator: "-").first.map(String.init) ?? ""
            let code: String?
            switch primary {
            case "de": code = "deu"
            case "fr": code = "fre"
            case "es": code = "spa"
            case "it": code = "ita"
            case "pt": code = "por"
            case "nl": code = "nld"
            case "ja": code = "jpn"
            case "zh": code = "zho"
            case "ru": code = "rus"
            case "pl": code = "pol"
            case "he", "iw": code = "heb"
            case "fi": code = "fin"
            case "el": code = "grc"
            case "la": code = "lat"
            case "en": code = "eng"
            default: code = nil
            }
            if let code, all.contains(where: { $0.id == code }) {
                result.insert(code)
                break
            }
        }
        return result
    }

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
