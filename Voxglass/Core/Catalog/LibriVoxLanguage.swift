import Foundation

/// Every language that appears in the LibriVox collection on the Internet Archive.
///
/// The `archive.org` `language` field is inconsistent — ISO 639-2/B and 639-3 codes,
/// full English names and the odd 2-letter code all occur — so each entry ORs every
/// form seen for that language. `swift run librivox-languages` re-scans the whole
/// collection, refreshes `LibriVoxLanguageCounts` and fails if archive.org shows a
/// `language` value that no entry claims, so this list stays complete.
///
/// `id` is the value stored in the user's selection. The original fifteen entries keep
/// their historical ids (`fre`, `nld`, …) so existing selections still load.
public struct LibriVoxLanguage: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    /// BCP-47 language code used to name the language in the user's own language.
    public var languageCode: String
    public var tokens: [String]

    /// Pseudo-language for items with no `language` field at all.
    public static let unspecifiedID = "und"

    public init(id: String, languageCode: String, tokens: [String]) {
        self.id = id
        self.languageCode = languageCode
        self.tokens = tokens
    }

    public var isUnspecified: Bool { id == Self.unspecifiedID }

    /// The language's name in the current interface language.
    public var displayName: String { displayName(locale: .current) }

    public func displayName(locale: Locale) -> String {
        let name = locale.localizedString(forLanguageCode: languageCode)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: languageCode)
            ?? id
        // Some languages (Finnish, Dutch, …) write language names in lower case.
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The language's English name, used as a search fallback.
    public var englishName: String { displayName(locale: Locale(identifier: "en")) }

    /// Number of LibriVox items in this language when the counts were last generated.
    public var itemCount: Int { LibriVoxLanguageCounts.counts[id] ?? 0 }

    public var clause: String {
        if isUnspecified { return "(*:* -language:[* TO *])" }
        // Multi-word names must be quoted, or `Greek` in `Ancient Greek` becomes a
        // free-text match against every field.
        return tokens
            .map { $0.contains(" ") ? "language:\"\($0)\"" : "language:\($0)" }
            .joined(separator: " OR ")
    }

    /// Whether this entry claims an archive.org `language` value.
    public func matches(token: String) -> Bool {
        let lowered = token.lowercased()
        return tokens.contains { $0.lowercased() == lowered }
    }

    public static let all: [LibriVoxLanguage] = [
        // The original fifteen; ids kept for stored selections.
        LibriVoxLanguage(id: "eng", languageCode: "en", tokens: ["eng", "English"]),
        LibriVoxLanguage(id: "deu", languageCode: "de", tokens: ["deu", "ger", "German"]),
        LibriVoxLanguage(id: "fre", languageCode: "fr", tokens: ["fre", "fra", "French"]),
        LibriVoxLanguage(id: "nld", languageCode: "nl", tokens: ["nld", "dut", "Dutch"]),
        LibriVoxLanguage(id: "spa", languageCode: "es", tokens: ["spa", "es", "Spanish"]),
        LibriVoxLanguage(id: "ita", languageCode: "it", tokens: ["ita", "Italian"]),
        LibriVoxLanguage(id: "por", languageCode: "pt", tokens: ["por", "Portuguese"]),
        LibriVoxLanguage(id: "rus", languageCode: "ru", tokens: ["rus", "Russian"]),
        LibriVoxLanguage(id: "zho", languageCode: "zh", tokens: ["zho", "chi", "Chinese"]),
        LibriVoxLanguage(id: "jpn", languageCode: "ja", tokens: ["jpn", "Japanese"]),
        LibriVoxLanguage(id: "lat", languageCode: "la", tokens: ["lat", "Latin"]),
        // Ancient Greek only. Modern Greek (`ell`) is its own entry below.
        LibriVoxLanguage(id: "grc", languageCode: "grc", tokens: ["grc", "Ancient Greek"]),
        LibriVoxLanguage(id: "pol", languageCode: "pl", tokens: ["pol", "Polish"]),
        LibriVoxLanguage(id: "fin", languageCode: "fi", tokens: ["fin", "Finnish"]),
        LibriVoxLanguage(id: "heb", languageCode: "he", tokens: ["heb", "Hebrew"]),
        // Everything else in the collection.
        LibriVoxLanguage(id: "ell", languageCode: "el", tokens: ["ell", "gre", "Modern Greek"]),
        LibriVoxLanguage(id: "mul", languageCode: "mul", tokens: ["mul"]),
        LibriVoxLanguage(id: "swe", languageCode: "sv", tokens: ["swe", "Swedish"]),
        LibriVoxLanguage(id: "cat", languageCode: "ca", tokens: ["cat", "Catalan"]),
        LibriVoxLanguage(id: "dan", languageCode: "da", tokens: ["dan", "Danish"]),
        LibriVoxLanguage(id: "epo", languageCode: "eo", tokens: ["epo", "Esperanto"]),
        LibriVoxLanguage(id: "chu", languageCode: "cu", tokens: ["chu"]),
        LibriVoxLanguage(id: "ukr", languageCode: "uk", tokens: ["ukr", "Ukrainian"]),
        LibriVoxLanguage(id: "tgl", languageCode: "tl", tokens: ["tgl", "Tagalog"]),
        LibriVoxLanguage(id: "bul", languageCode: "bg", tokens: ["bul", "Bulgarian"]),
        LibriVoxLanguage(id: "kor", languageCode: "ko", tokens: ["kor", "Korean"]),
        LibriVoxLanguage(id: "ron", languageCode: "ro", tokens: ["ron", "rum", "Romanian"]),
        LibriVoxLanguage(id: "enm", languageCode: "enm", tokens: ["enm"]),
        LibriVoxLanguage(id: "ara", languageCode: "ar", tokens: ["ara", "Arabic"]),
        LibriVoxLanguage(id: "hin", languageCode: "hi", tokens: ["hin", "Hindi"]),
        LibriVoxLanguage(id: "hun", languageCode: "hu", tokens: ["hun", "Hungarian"]),
        LibriVoxLanguage(id: "tam", languageCode: "ta", tokens: ["tam", "Tamil"]),
        LibriVoxLanguage(id: "gle", languageCode: "ga", tokens: ["gle", "Irish"]),
        LibriVoxLanguage(id: "ang", languageCode: "ang", tokens: ["ang"]),
        LibriVoxLanguage(id: "nor", languageCode: "no", tokens: ["nor", "nob", "Norwegian"]),
        LibriVoxLanguage(id: "yue", languageCode: "yue", tokens: ["yue", "Cantonese"]),
        LibriVoxLanguage(id: "urd", languageCode: "ur", tokens: ["urd", "Urdu"]),
        LibriVoxLanguage(id: "luo", languageCode: "luo", tokens: ["luo"]),
        LibriVoxLanguage(id: "mri", languageCode: "mi", tokens: ["mri", "mao", "Maori"]),
        LibriVoxLanguage(id: "ces", languageCode: "cs", tokens: ["ces", "cze", "Czech"]),
        LibriVoxLanguage(id: "lav", languageCode: "lv", tokens: ["lav", "Latvian"]),
        LibriVoxLanguage(id: "ind", languageCode: "id", tokens: ["ind", "Indonesian"]),
        LibriVoxLanguage(id: "ltz", languageCode: "lb", tokens: ["ltz", "Luxembourgish"]),
        LibriVoxLanguage(id: "hrv", languageCode: "hr", tokens: ["hrv", "Croatian"]),
        LibriVoxLanguage(id: "fas", languageCode: "fa", tokens: ["fas", "per", "far", "Persian"]),
        LibriVoxLanguage(id: "jav", languageCode: "jv", tokens: ["jav", "Javanese"]),
        LibriVoxLanguage(id: "ceb", languageCode: "ceb", tokens: ["ceb", "Cebuano"]),
        LibriVoxLanguage(id: "tel", languageCode: "te", tokens: ["tel", "Telugu"]),
        LibriVoxLanguage(id: "mkd", languageCode: "mk", tokens: ["mkd", "mac", "Macedonian"]),
        LibriVoxLanguage(id: unspecifiedID, languageCode: "und", tokens: [])
    ]

    /// How many of the largest languages the picker shows before "All languages".
    public static let popularCount = 10

    /// The largest languages by item count, plus the device's language when LibriVox
    /// has books in it. The unspecified pseudo-language is never "popular".
    public static func popular(preferredLanguages: [String] = Locale.preferredLanguages) -> [LibriVoxLanguage] {
        var result = Array(
            all.filter { !$0.isUnspecified }
                .sorted { $0.itemCount > $1.itemCount }
                .prefix(popularCount)
        )
        for tag in preferredLanguages {
            if let device = language(forDeviceLanguage: tag) {
                if !result.contains(device) { result.append(device) }
                break
            }
        }
        return result
    }

    /// Every language, sorted by its name in `locale`, with "Unknown language" last.
    public static func sortedByName(locale: Locale = .current) -> [LibriVoxLanguage] {
        all.sorted { lhs, rhs in
            if lhs.isUnspecified != rhs.isUnspecified { return rhs.isUnspecified }
            return lhs.displayName(locale: locale)
                .compare(rhs.displayName(locale: locale), options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                == .orderedAscending
        }
    }

    /// Whether `language` matches a picker search term in its localized name, English
    /// name or any archive.org token.
    public static func matches(_ language: LibriVoxLanguage, search: String, locale: Locale = .current) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return language.displayName(locale: locale).range(of: term, options: options, locale: locale) != nil
            || language.englishName.range(of: term, options: options) != nil
            || language.id.range(of: term, options: options) != nil
            || language.tokens.contains { $0.range(of: term, options: options) != nil }
    }

    public static var defaultSelection: Set<String> { deviceDefaultSelection() }

    /// Default language selection for a new install, retaining English while
    /// adding the device's primary language when LibriVox has books in it.
    public static func deviceDefaultSelection(preferredLanguages: [String] = Locale.preferredLanguages) -> Set<String> {
        var result: Set<String> = ["eng"]
        for tag in preferredLanguages {
            if let language = language(forDeviceLanguage: tag) {
                result.insert(language.id)
                break
            }
        }
        return result
    }

    /// The entry for a device language tag such as `de-DE`, `zh-Hant-TW` or `el-GR`.
    static func language(forDeviceLanguage tag: String) -> LibriVoxLanguage? {
        var primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch primary {
        case "iw": primary = "he"
        case "nb", "nn": primary = "no"
        case "fil": primary = "tl"
        default: break
        }
        return all.first { !$0.isUnspecified && $0.languageCode == primary }
    }

    public static func language(withID id: String) -> LibriVoxLanguage? {
        all.first { $0.id == id }
    }

    /// The entry that claims an archive.org `language` value, if any.
    public static func language(forToken token: String) -> LibriVoxLanguage? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return all.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame || $0.matches(token: trimmed) }
    }

    /// Builds a query fragment restricting results to the selected languages,
    /// e.g. `" AND (language:eng OR language:English OR language:deu OR ...)"`.
    /// Returns `""` when nothing or everything is selected (both mean "all
    /// languages"), leaving the delegated query unfiltered.
    public static func clause(for codes: Set<String>) -> String {
        let selected = all.filter { codes.contains($0.id) }
        guard !selected.isEmpty, selected.count < all.count else { return "" }
        let joined = selected.map(\.clause).joined(separator: " OR ")
        return " AND (\(joined))"
    }
}
