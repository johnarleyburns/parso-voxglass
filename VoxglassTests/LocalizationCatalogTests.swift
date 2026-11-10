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

    // MARK: Static Watch management UI (issue #256)

    private static let staticWatchKeys = [
        "Send and manage books from Voxglass on your iPhone.",
        "No books installed on this watch.",
        "Sync Now available when connected to iPhone.",
        "Installed audio",
        "Audio submitted by iPhone; installation is unconfirmed.",
        "Diagnostics",
        "Refresh",
        "Sync Status",
        "Reset watch listening data",
        "Close and reopen Voxglass on this watch to finish reset.",
        "Reset watch listening data?",
        "Reset",
        "Deletes watch audiobooks, artwork, and local listening settings on next launch. Your iPhone originals and unsubmitted narration review events are kept.",
        "About Book"
    ]

    @Test func staticWatchManagementKeysAreTranslatedInEveryLocale() throws {
        for key in Self.staticWatchKeys {
            let localizations = try Self.localizations(catalog: "VoxglassWatch/Resources/Localizable.xcstrings", key: key)
            for language in supportedLanguages {
                let unit = try #require(Self.units(localizations[language]).first, "\(language) missing for \(key)")
                #expect(unit["state"] as? String == "translated", "\(language) state for \(key)")
                #expect((unit["value"] as? String)?.isEmpty == false, "\(language) blank for \(key)")
            }
        }
    }

    // MARK: Static iPhone/iPad labels (issue #257)

    private static let staticPhoneKeys = [
        "Find Failed",
        "READ WITH AI · PROJECT GUTENBERG",
        "Searching Project Gutenberg",
        "Download to Apple Watch?",
        "Reconnect Audio",
        "Reselect Folder or File",
        "Select AI Voice",
        "This audiobook needs its audio file reconnected on this device.",
        "Choose File or Folder",
        "Choose…",
        "Confirm and Reconnect",
        "Add Bookmark?",
        "View Bookmarks",
        "Starts playback in the mini player",
        "Read with AI Voice",
        "Download more voices in iPhone Settings > Accessibility > Read & Speak > System Voice, then return here.",
        "Your My Books library, playback position, bookmarks, and favorites sync across devices using your private iCloud account. No app account required.",
        "Only books you send from this iPhone appear on Apple Watch, prepared as 96 kbps AAC. Use “Download to Apple Watch” on a book page or in its My Books context menu; manage them in My Books → On My Watch.",
        "No watch report received this session.",
        "Cancel watch audio preparation",
        "Read with AI",
        "Voxglass will download the EPUB once, keep its text on this iPhone, and read it aloud with your selected system voice.",
        "Book Preview",
        "Couldn't Prepare Book",
        "All Books",
        "On My Watch",
        "Remove from Apple Watch",
        "The iPhone original stays in My Books.",
        "Installed on Apple Watch",
        "Removal sent to Apple Watch.",
        "Transferring audio to Apple Watch",
        "Read a document with AI",
        "Choose an EPUB or text-based PDF from Files. Voxglass keeps a local text copy and reads it with the iPhone’s built-in voice.",
        "Choose EPUB or PDF"
    ]

    @Test func staticPhoneLabelsAreTranslatedInEveryLocale() throws {
        #expect(Self.staticPhoneKeys.count == 34)
        for key in Self.staticPhoneKeys {
            let localizations = try Self.localizations(catalog: "Voxglass/Resources/Localizable.xcstrings", key: key)
            for language in supportedLanguages {
                let unit = try #require(Self.units(localizations[language]).first, "\(language) missing for \(key)")
                #expect(unit["state"] as? String == "translated", "\(language) state for \(key)")
                #expect((unit["value"] as? String)?.isEmpty == false, "\(language) blank for \(key)")
            }
        }
    }

    @Test func staticPhoneLabelsAreNotEnglishFallbacksInDeJaHeZhHans() throws {
        for key in Self.staticPhoneKeys {
            let localizations = try Self.localizations(catalog: "Voxglass/Resources/Localizable.xcstrings", key: key)
            for language in ["de", "ja", "he", "zh-Hans"] {
                let value = try #require(Self.units(localizations[language]).first?["value"] as? String)
                #expect(value != key, "\(language) is still English for \(key)")
            }
        }
    }

    @Test func staticPhoneLabelsKeepPunctuationArrowsAndBitrate() throws {
        let catalog = "Voxglass/Resources/Localizable.xcstrings"
        let watchKey = "Only books you send from this iPhone appear on Apple Watch, prepared as 96 kbps AAC. Use “Download to Apple Watch” on a book page or in its My Books context menu; manage them in My Books → On My Watch."
        #expect(watchKey.contains("“Download to Apple Watch”") && watchKey.contains("→") && watchKey.contains("96 kbps"))
        let watch = try Self.localizations(catalog: catalog, key: watchKey)
        for language in supportedLanguages {
            let value = try #require(Self.units(watch[language]).first?["value"] as? String)
            #expect(value.contains("96 kbps"), "\(language) lost the 96 kbps value")
            #expect(value.contains("→") || value.contains("←"), "\(language) lost the navigation arrow")
        }
        let document = "Choose an EPUB or text-based PDF from Files. Voxglass keeps a local text copy and reads it with the iPhone’s built-in voice."
        let doc = try Self.localizations(catalog: catalog, key: document)
        #expect(doc["en"] != nil && doc["en-GB"] != nil)
        let en = try #require(Self.units(doc["en"]).first?["value"] as? String)
        #expect(en.contains("’"), "en curly apostrophe lost")
        for key in Self.staticPhoneKeys where key.contains("?") || key.contains("…") || key.contains("·") {
            let localizations = try Self.localizations(catalog: catalog, key: key)
            let en = try #require(Self.units(localizations["en"]).first?["value"] as? String)
            #expect(en == key, "English value must equal the source key for \(key)")
        }
        // Question-mark titles keep a question mark in every locale (Greek uses ;).
        for key in ["Download to Apple Watch?", "Add Bookmark?"] {
            let localizations = try Self.localizations(catalog: catalog, key: key)
            for language in supportedLanguages {
                let value = try #require(Self.units(localizations[language]).first?["value"] as? String)
                let mark = language == "el" ? ";" : "?"
                #expect(value.hasSuffix(mark) || value.hasSuffix("?"), "\(language) lost the question mark for \(key)")
            }
        }
    }

    @Test func reconnectMessageIsTranslatedInCoreCatalog() throws {
        let key = "This audiobook needs its audio file reconnected on this device."
        let localizations = try Self.localizations(catalog: "Voxglass/Core/Resources/Localizable.xcstrings", key: key)
        for language in supportedLanguages {
            let unit = try #require(Self.units(localizations[language]).first)
            #expect(unit["state"] as? String == "translated")
            #expect((unit["value"] as? String)?.isEmpty == false)
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
