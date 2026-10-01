import Foundation
import Testing

@Suite struct LocalizationCatalogTests {
    private let supportedLanguages = ["de", "fr", "es", "it", "pt-BR", "nl", "ja", "zh-Hans", "ru", "pl", "he"]

    @Test func catalogsHaveContextAndNoStaleEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "xcstrings" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: file)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let strings = json?["strings"] as? [String: Any] ?? [:]
            if file.path.hasSuffix("/Voxglass/Resources/Localizable.xcstrings") {
                #expect(strings.count >= 800, "The app catalog must contain the extracted UI surface")
            }
            for (key, raw) in strings {
                let value = raw as? [String: Any] ?? [:]
                #expect((value["comment"] as? String)?.isEmpty == false, "Missing translator context for \(key) in \(file.path)")
                #expect(value["extractionState"] as? String != "stale", "Stale localization key \(key)")
                if value["shouldTranslate"] as? Bool == false { continue }
                let localizations = value["localizations"] as? [String: Any] ?? [:]
                let englishPlurals = Self.pluralUnits(localizations["en"])
                for language in supportedLanguages {
                    #expect(localizations[language] != nil, "Missing \(language) translation for \(key)")
                    let units = Self.units(localizations[language])
                    #expect(!units.isEmpty, "Empty \(language) translation for \(key)")
                    for unit in units {
                        let state = unit["state"] as? String
                        #expect(state == "translated" || state == "needs_review", "Bad \(language) state for \(key)")
                        #expect((unit["value"] as? String)?.isEmpty == false, "Blank \(language) value for \(key)")
                    }
                    if !englishPlurals.isEmpty {
                        #expect(!Self.pluralUnits(localizations[language]).isEmpty,
                                "\(key) varies by plural in English but not in \(language)")
                    }
                }
            }
        }
    }

    /// Every string unit of one localization, whether plain, a plural
    /// variation, or an App Shortcuts phrase set (one value per phrase).
    private static func units(_ entry: Any?) -> [[String: Any]] {
        guard let entry = entry as? [String: Any] else { return [] }
        if let unit = entry["stringUnit"] as? [String: Any] { return [unit] }
        if let set = entry["stringSet"] as? [String: Any] {
            let values = set["values"] as? [String] ?? []
            return values.map { ["state": set["state"] ?? "", "value": $0] }
        }
        return pluralUnits(entry)
    }

    /// The string units of a localization's plural variations, if it has any.
    private static func pluralUnits(_ entry: Any?) -> [[String: Any]] {
        guard let entry = entry as? [String: Any],
              let variations = entry["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return [] }
        return plural.values.compactMap { ($0 as? [String: Any])?["stringUnit"] as? [String: Any] }
    }
}
