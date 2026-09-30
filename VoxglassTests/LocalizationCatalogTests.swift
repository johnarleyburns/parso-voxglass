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
                let localizations = value["localizations"] as? [String: Any] ?? [:]
                for language in supportedLanguages {
                    #expect(localizations[language] != nil)
                    let entry = localizations[language] as? [String: Any]
                    let unit = entry?["stringUnit"] as? [String: Any]
                    let state = unit?["state"] as? String
                    #expect(state == "translated" || state == "needs_review")
                    #expect(unit?["state"] as? String != "stale", "Stale \(language) translation for \(key)")
                }
            }
        }
    }
}
