import Foundation
import Testing
@testable import VoxglassCore

@Suite
struct ReadWithAIVoicePreferencesTests {
    @Test func aBookVoiceIsDurableAndAlsoBecomesTheDefaultForNewBooks() throws {
        let name = "read-ai-voice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let book = UUID()
        let choice = ReadWithAIVoicePreference(identifier: "com.apple.voice.ava", name: "Ava", language: "en-US")

        ReadWithAIVoicePreferences.set(choice, for: book, in: defaults)

        #expect(ReadWithAIVoicePreferences.preference(for: book, in: defaults) == choice)
        #expect(ReadWithAIVoicePreferences.defaultPreference(in: defaults) == choice)
        #expect(defaults.string(forKey: AppPreferencesStore.Keys.readWithAIVoiceIdentifier) == choice.identifier)
    }

    @Test func eachBookKeepsItsOwnVoiceWhenTheDefaultChanges() throws {
        let name = "read-ai-voice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID()
        let second = UUID()
        let ava = ReadWithAIVoicePreference(identifier: "ava", name: "Ava", language: "en-US")
        let samantha = ReadWithAIVoicePreference(identifier: "samantha", name: "Samantha", language: "en-US")

        ReadWithAIVoicePreferences.set(ava, for: first, in: defaults)
        ReadWithAIVoicePreferences.set(samantha, for: second, in: defaults)

        #expect(ReadWithAIVoicePreferences.preference(for: first, in: defaults) == ava)
        #expect(ReadWithAIVoicePreferences.preference(for: second, in: defaults) == samantha)
    }

    @Test func legacySingleVoiceSettingMigratesWithoutResettingToAutomatic() throws {
        let name = "read-ai-voice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("com.apple.voice.ava", forKey: AppPreferencesStore.Keys.readWithAIVoiceIdentifier)

        #expect(ReadWithAIVoicePreferences.defaultPreference(in: defaults).identifier == "com.apple.voice.ava")
    }
}
