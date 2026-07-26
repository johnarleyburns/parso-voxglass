import Testing
import Foundation
@testable import VoxglassCore

@Suite struct EQPresetStoreTests {

    private func makeStore() -> (EQPresetStore, UserDefaults) {
        let suite = "eq-preset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (EQPresetStore(defaults: defaults), defaults)
    }

    @Test func builtInsAlwaysPresent() {
        let (store, _) = makeStore()
        let names = store.all.map(\.name)
        #expect(names.contains("Flat"))
        #expect(names.contains("Concert Hall"))
        #expect(names.contains("Spoken Word"))
        #expect(names.contains("78 rpm"))
        #expect(store.savedPresets().count == 0)
    }

    @Test func saveLoadDeleteRoundTrip() {
        let (store, _) = makeStore()
        let preset = EQPreset(name: "My Room", gains: [1, 2, 3, 0, 0, 0, -1, -2, -3, 4])

        store.save(preset)
        #expect(store.savedPresets().count == 1)
        #expect(store.savedPresets().first?.name == "My Room")
        #expect(store.savedPresets().first?.gains == preset.gains)
        #expect(!(store.savedPresets().first?.isBuiltIn ?? true))
        #expect(store.all.count == EQPreset.builtInPresets.count + 1)

        store.delete(preset.id)
        #expect(store.savedPresets().count == 0)
        #expect(store.all.count == EQPreset.builtInPresets.count)
    }

    @Test func saveUpdatesExistingPresetByID() {
        let (store, _) = makeStore()
        var preset = EQPreset(name: "Tweakable", gains: Array(repeating: 0, count: 10))
        store.save(preset)
        preset.gains[0] = 9
        store.save(preset)

        #expect(store.savedPresets().count == 1)
        #expect(store.savedPresets().first?.gains[0] == 9)
    }

    @Test func persistenceAcrossStoreInstances() {
        let suite = "eq-preset-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preset = EQPreset(name: "Persisted", gains: Array(repeating: 2, count: 10))
        EQPresetStore(defaults: defaults).save(preset)

        let reopened = EQPresetStore(defaults: defaults)
        #expect(reopened.savedPresets().first?.name == "Persisted")
    }
}

@Suite struct EQSettingsStoreTests {

    private func makeStore() -> EQSettingsStore {
        let defaults = UserDefaults(suiteName: "eq-settings-\(UUID().uuidString)")!
        return EQSettingsStore(defaults: defaults)
    }

    @Test func defaultsAreFlatAndDisengaged() {
        let store = makeStore()
        #expect(!(store.isEngaged))
        #expect(store.gains == Array(repeating: 0, count: 10))
    }

    @Test func engagedAndGainsPersist() {
        let suite = "eq-settings-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = EQSettingsStore(defaults: defaults)

        store.isEngaged = true
        store.gains = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        let reopened = EQSettingsStore(defaults: defaults)
        #expect(reopened.isEngaged)
        #expect(reopened.gains == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    @Test func gainsRejectWrongBandCount() {
        let store = makeStore()
        store.gains = [1, 2, 3]
        #expect(store.gains == Array(repeating: 0, count: 10))
    }
}
