import Foundation
import Testing

@Suite struct LocalizationCatalogTests {
    private let supportedLanguages = ["de", "fr", "es", "it", "pt-BR", "nl", "ja", "zh-Hans", "zh-Hant", "ru", "pl", "he", "fi", "el", "en-GB"]

    @Test func catalogsHaveContextAndNoStaleEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "xcstrings" && !$0.path.contains("/.build/") } ?? []
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

    // MARK: Composed Watch receipts and My Books import failure (issue #255)

    private static let composedKeys: [(catalog: String, key: String, placeholders: [String])] = [
        ("VoxglassWatch/Resources/Localizable.xcstrings", "Audio receipt: %@", ["%@"]),
        ("VoxglassWatch/Resources/Localizable.xcstrings", "Artwork receipt: %@", ["%@"]),
        ("VoxglassWatch/Resources/Localizable.xcstrings", "Watch report: %@", ["%@"]),
        ("Voxglass/Resources/Localizable.xcstrings",
         "My Books synced %lld records; %lld records could not be imported and will retry.\n%@",
         ["%1$lld", "%2$lld", "%3$@"])
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func localizations(catalog: String, key: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(catalog))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "Missing catalog key \(key)")
        return try #require(entry["localizations"] as? [String: Any])
    }

    @Test func composedMessageKeysAreTranslatedInEveryLocale() throws {
        for (catalog, key, placeholders) in Self.composedKeys {
            let localizations = try Self.localizations(catalog: catalog, key: key)
            for language in supportedLanguages {
                let unit = try #require(Self.units(localizations[language]).first, "\(language) missing for \(key)")
                #expect(unit["state"] as? String == "translated", "\(language) state for \(key)")
                let value = unit["value"] as? String ?? ""
                #expect(!value.isEmpty)
                for placeholder in placeholders {
                    #expect(value.contains(placeholder), "\(language) value for \(key) must keep \(placeholder)")
                }
            }
        }
    }

    @Test func germanJapaneseAndHebrewWrappersAreTranslatedAndKeepPayloadSlot() throws {
        for (catalog, key, _) in Self.composedKeys {
            let localizations = try Self.localizations(catalog: catalog, key: key)
            for language in ["de", "ja", "he"] {
                let value = try #require(Self.units(localizations[language]).first?["value"] as? String)
                #expect(value != key, "\(language) wrapper for \(key) is still English")
                let rendered = value
                    .replacingOccurrences(of: "%3$@", with: "PAYLOAD")
                    .replacingOccurrences(of: "%@", with: "PAYLOAD")
                #expect(rendered.contains("PAYLOAD"), "Payload must stay verbatim in \(language)")
            }
        }
    }

    @Test func composedMessagesDoNotUseStringConcatenation() throws {
        let watch = try String(contentsOf: Self.root.appendingPathComponent("VoxglassWatch/WatchListeningViews.swift"), encoding: .utf8)
        let settings = try String(contentsOf: Self.root.appendingPathComponent("Voxglass/Features/Settings/SettingsView.swift"), encoding: .utf8)
        for forbidden in ["Text(\"Audio receipt: \" +", "Text(\"Artwork receipt: \" +", "Text(\"Watch report: \" +"] {
            #expect(!watch.contains(forbidden), "Concatenated message: \(forbidden)")
        }
        #expect(!settings.contains("will retry.\\n\" +"), "My Books import failure must be one localized key")
        #expect(watch.contains("String(localized: \"Audio receipt: \\(services.session.audioReceipt)\")"))
        #expect(settings.contains("String(localized: \"My Books synced"))
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
