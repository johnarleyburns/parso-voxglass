import Foundation
import Testing
@testable import VoxglassCore

@Suite struct AuthoringSyncPreferencesTests {
    @Test func narrationSyncDefaultsOnWithoutOverridingAnExplicitOptOut() {
        let suiteName = "AuthoringSyncPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppPreferencesStore.authoringV2SyncEnabled(in: defaults))

        defaults.set(false, forKey: AppPreferencesStore.Keys.authoringV2SyncEnabled)
        #expect(!AppPreferencesStore.authoringV2SyncEnabled(in: defaults))

        defaults.set(true, forKey: AppPreferencesStore.Keys.authoringV2SyncEnabled)
        #expect(AppPreferencesStore.authoringV2SyncEnabled(in: defaults))
    }
}
