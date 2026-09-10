import Foundation
import VoxglassCore

/// A placeholder `ProductionSyncTransport` for the Mac app.
///
/// `CloudKitProductionSync` calls `CKContainer(identifier:)`, which Apple
/// documents as validating the app's CloudKit entitlement at init time — with
/// no entitlement present it traps the process immediately (not a throwing
/// failure). U0 deliberately ships `VoxglassMac` with no CloudKit entitlement
/// (SPEC §17: U0 needs no signing at all), so wiring the real CloudKit
/// transport in here would crash the app on every launch. CloudKit sync is a
/// U1 concern ("U1 writes to users' CloudKit records" — AGENT_BRIEF); this
/// stands in until U1 adds back the `com.apple.developer.icloud-services`
/// entitlement and swaps this for `CloudKitProductionSync()`.
struct NoopProductionSyncTransport: ProductionSyncTransport {
    func accountStatus() async -> SyncAccountStatus { .unavailable }

    func fetchZoneChanges(after token: SyncChangeToken?) async throws -> ZoneFetchResult {
        ZoneFetchResult()
    }

    func pushRecords(_ records: [SyncRecord]) async throws {
        throw SyncError.transport("Sync is not yet available on the Mac (landing in U1).")
    }

    func fetchRecords(_ recordNames: [String]) async throws -> [SyncRecord] { [] }

    func deleteRecords(_ recordNames: [String]) async throws {}
}
