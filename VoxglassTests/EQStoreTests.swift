import XCTest
@testable import VoxglassCore

final class EQPresetStoreTests: XCTestCase {

    private func makeStore() -> (EQPresetStore, UserDefaults) {
        let suite = "eq-preset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (EQPresetStore(defaults: defaults), defaults)
    }

    func testBuiltInsAlwaysPresent() {
        let (store, _) = makeStore()
        let names = store.all.map(\.name)
        XCTAssertTrue(names.contains("Flat"))
        XCTAssertTrue(names.contains("Concert Hall"))
        XCTAssertTrue(names.contains("Spoken Word"))
        XCTAssertTrue(names.contains("78 rpm"))
        XCTAssertEqual(store.savedPresets().count, 0)
    }

    func testSaveLoadDeleteRoundTrip() {
        let (store, _) = makeStore()
        let preset = EQPreset(name: "My Room", gains: [1, 2, 3, 0, 0, 0, -1, -2, -3, 4])

        store.save(preset)
        XCTAssertEqual(store.savedPresets().count, 1)
        XCTAssertEqual(store.savedPresets().first?.name, "My Room")
        XCTAssertEqual(store.savedPresets().first?.gains, preset.gains)
        XCTAssertFalse(store.savedPresets().first?.isBuiltIn ?? true)
        XCTAssertEqual(store.all.count, EQPreset.builtInPresets.count + 1)

        store.delete(preset.id)
        XCTAssertEqual(store.savedPresets().count, 0)
        XCTAssertEqual(store.all.count, EQPreset.builtInPresets.count)
    }

    func testSaveUpdatesExistingPresetByID() {
        let (store, _) = makeStore()
        var preset = EQPreset(name: "Tweakable", gains: Array(repeating: 0, count: 10))
        store.save(preset)
        preset.gains[0] = 9
        store.save(preset)

        XCTAssertEqual(store.savedPresets().count, 1)
        XCTAssertEqual(store.savedPresets().first?.gains[0], 9)
    }

    func testPersistenceAcrossStoreInstances() {
        let suite = "eq-preset-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preset = EQPreset(name: "Persisted", gains: Array(repeating: 2, count: 10))
        EQPresetStore(defaults: defaults).save(preset)

        let reopened = EQPresetStore(defaults: defaults)
        XCTAssertEqual(reopened.savedPresets().first?.name, "Persisted")
    }
}

final class EQSettingsStoreTests: XCTestCase {

    private func makeStore() -> EQSettingsStore {
        let defaults = UserDefaults(suiteName: "eq-settings-\(UUID().uuidString)")!
        return EQSettingsStore(defaults: defaults)
    }

    func testDefaultsAreFlatAndDisengaged() {
        let store = makeStore()
        XCTAssertFalse(store.isEngaged)
        XCTAssertEqual(store.gains, Array(repeating: 0, count: 10))
    }

    func testEngagedAndGainsPersist() {
        let suite = "eq-settings-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = EQSettingsStore(defaults: defaults)

        store.isEngaged = true
        store.gains = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        let reopened = EQSettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.isEngaged)
        XCTAssertEqual(reopened.gains, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    func testGainsRejectWrongBandCount() {
        let store = makeStore()
        store.gains = [1, 2, 3]
        XCTAssertEqual(store.gains, Array(repeating: 0, count: 10))
    }
}
