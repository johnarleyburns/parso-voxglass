import Foundation

public struct KVSMigrationShim {
    private static let migrationKey = "voxglass.migratedKVSToCloudKit"

    public static func migrateIfNeeded(database: AppDatabase) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let kvs = NSUbiquitousKeyValueStore.default
        _ = kvs.dictionaryRepresentation

        // Mark migrated — existing KVS data is pushed by VoxglassCloudSync on next sync,
        // and new CloudKit engine handles ongoing sync.
        defaults.set(true, forKey: migrationKey)
    }

    public static var isMigrated: Bool {
        UserDefaults.standard.bool(forKey: migrationKey)
    }
}
