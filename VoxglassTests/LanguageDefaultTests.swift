import Testing
@testable import VoxglassCore

@Suite struct LanguageDefaultTests {
    @Test func mapsSupportedDeviceLanguagesAndAlwaysKeepsEnglish() {
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["de-DE"]) == ["eng", "deu"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["pt-BR"]) == ["eng", "por"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["zh-Hans-CN"]) == ["eng", "zho"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["he-IL"]) == ["eng", "heb"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["en-GB"]) == ["eng"])
        #expect(LibriVoxLanguage.deviceDefaultSelection(preferredLanguages: ["xx"]) == ["eng"])
    }
}
