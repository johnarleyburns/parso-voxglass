import Foundation
import Testing
@testable import VoxglassCore

@Suite struct LanguageDefaultTests {
    @Test func mapsSupportedDeviceLanguagesAndAlwaysKeepsEnglish() {
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["de-DE"]) == ["eng", "deu"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["pt-BR"]) == ["eng", "por"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["zh-Hans-CN"]) == ["eng", "zho"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["zh-Hant-TW"]) == ["eng", "zho"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["he-IL"]) == ["eng", "heb"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["iw"]) == ["eng", "heb"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["fi-FI"]) == ["eng", "fin"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["sv-SE"]) == ["eng", "swe"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["nb-NO"]) == ["eng", "nor"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["en-GB"]) == ["eng"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["xx"]) == ["eng"])
    }

    /// A Greek device means Modern Greek books, not Ancient Greek.
    @Test func greekDeviceSelectsModernGreek() {
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["el-GR"]) == ["eng", "ell"])
    }
}

@Suite struct LibriVoxLanguageTableTests {
    @Test func idsAndTokensAreUnique() {
        let ids = LibriVoxLanguage.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        var owner: [String: String] = [:]
        for language in LibriVoxLanguage.all {
            for token in language.tokens {
                let key = token.lowercased()
                #expect(owner[key] == nil, "\(token) claimed by \(owner[key] ?? "") and \(language.id)")
                owner[key] = language.id
            }
        }
    }

    @Test func originalSelectionIDsStillResolve() {
        for id in ["eng", "deu", "fre", "nld", "spa", "ita", "por", "rus", "zho", "jpn", "lat", "grc", "pol", "fin", "heb"] {
            #expect(LibriVoxLanguage.language(withID: id) != nil, "\(id)")
        }
    }

    @Test func everyLanguageHasBooksInTheGeneratedCounts() {
        for language in LibriVoxLanguage.all {
            #expect(language.itemCount > 0, "\(language.id) has no generated count")
        }
        #expect(!LibriVoxLanguageCounts.generatedOn.isEmpty)
    }

    @Test func modernAndAncientGreekStaySeparate() {
        #expect(LibriVoxLanguage.language(forToken: "ell")?.id == "ell")
        #expect(LibriVoxLanguage.language(forToken: "gre")?.id == "ell")
        #expect(LibriVoxLanguage.language(forToken: "grc")?.id == "grc")
        let ancient = LibriVoxLanguage.clause(for: ["grc"])
        #expect(ancient.contains("language:grc"))
        #expect(!ancient.contains("language:ell"))
        #expect(!ancient.contains("language:gre "))
        #expect(ancient.contains("language:\"Ancient Greek\""))
    }

    @Test func tokenVariantsResolveToOneLanguage() {
        #expect(LibriVoxLanguage.language(forToken: "ger")?.id == "deu")
        #expect(LibriVoxLanguage.language(forToken: "fra")?.id == "fre")
        #expect(LibriVoxLanguage.language(forToken: "es")?.id == "spa")
        #expect(LibriVoxLanguage.language(forToken: "far")?.id == "fas")
        #expect(LibriVoxLanguage.language(forToken: " English ")?.id == "eng")
        #expect(LibriVoxLanguage.language(forToken: "xyz") == nil)
    }

    @Test func clauseORsEveryTokenAndAddsUntaggedItems() {
        let clause = LibriVoxLanguage.clause(for: ["deu", LibriVoxLanguage.unspecifiedID])
        #expect(clause == " AND (language:deu OR language:ger OR language:German OR (*:* -language:[* TO *]))")
    }

    @Test func clauseIsEmptyForNoneOrAllLanguages() {
        #expect(LibriVoxLanguage.clause(for: []) == "")
        #expect(LibriVoxLanguage.clause(for: Set(LibriVoxLanguage.all.map(\.id))) == "")
        #expect(LibriVoxLanguage.clause(for: ["not-a-language"]) == "")
    }

    @Test func everyLanguageHasANameInEveryInterfaceLanguage() {
        let interfaceLanguages = ["en", "en-GB", "de", "fr", "es", "it", "pt-BR", "nl", "ja", "zh-Hans", "zh-Hant", "ru", "pl", "he", "fi", "el"]
        for identifier in interfaceLanguages {
            let locale = Locale(identifier: identifier)
            for language in LibriVoxLanguage.all {
                let name = language.displayName(locale: locale)
                #expect(!name.isEmpty && name != language.id && name != language.languageCode, "\(language.id) in \(identifier): \(name)")
            }
        }
    }

    @Test func namesFollowTheInterfaceLanguage() {
        let greek = LibriVoxLanguage.language(withID: "ell")!
        #expect(greek.displayName(locale: Locale(identifier: "en")) == "Greek")
        #expect(greek.displayName(locale: Locale(identifier: "de")) == "Griechisch")
        // Finnish writes language names in lower case; the picker capitalizes them.
        #expect(LibriVoxLanguage.language(withID: "eng")!.displayName(locale: Locale(identifier: "fi")) == "Englanti")
    }

    @Test func popularListsTheLargestLanguagesAndTheDeviceLanguage() {
        let popular = LibriVoxLanguage.popular(preferredLanguages: ["sv-SE"])
        #expect(popular.first?.id == "eng")
        #expect(popular.count == LibriVoxLanguage.popularCount + 1)
        #expect(popular.last?.id == "swe")
        #expect(!popular.contains { $0.isUnspecified })
        #expect(LibriVoxLanguage.popular(preferredLanguages: ["de-DE"]).count == LibriVoxLanguage.popularCount)
    }

    @Test func sortedByNamePutsUnknownLast() {
        let sorted = LibriVoxLanguage.sortedByName(locale: Locale(identifier: "en"))
        #expect(sorted.count == LibriVoxLanguage.all.count)
        #expect(sorted.last?.isUnspecified == true)
        #expect(sorted.first?.displayName(locale: Locale(identifier: "en")) == "Ancient Greek")
    }

    @Test func searchMatchesLocalizedEnglishAndCodes() {
        let german = LibriVoxLanguage.language(withID: "deu")!
        #expect(LibriVoxLanguage.matches(german, search: "deutsch", locale: Locale(identifier: "de")))
        #expect(LibriVoxLanguage.matches(german, search: "German", locale: Locale(identifier: "ja")))
        #expect(LibriVoxLanguage.matches(german, search: "ger", locale: Locale(identifier: "ja")))
        #expect(!LibriVoxLanguage.matches(german, search: "French", locale: Locale(identifier: "en")))
    }
}

@Suite struct LanguageSelectionStorageTests {
    @Test func emptySelectionMeansEveryLanguage() {
        let raw = AppPreferencesStore.encodeLanguages([])
        #expect(raw == AppPreferencesStore.allLanguagesValue)
        #expect(AppPreferencesStore.decodeLanguages(raw).isEmpty)
        #expect(LibriVoxLanguage.clause(for: AppPreferencesStore.decodeLanguages(raw)) == "")
    }

    @Test func neverSetFallsBackToTheDeviceDefault() {
        #expect(AppPreferencesStore.decodeLanguages("") == LibriVoxLanguage.defaultSelection)
    }

    @Test func storedSelectionsRoundTrip() {
        #expect(AppPreferencesStore.decodeLanguages("eng,grc") == ["eng", "grc"])
        #expect(AppPreferencesStore.decodeLanguages(AppPreferencesStore.encodeLanguages(["ell", "mul"])) == ["ell", "mul"])
    }
}
