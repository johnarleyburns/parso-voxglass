import Foundation

/// Keeps the Mac startup contract testable without constructing a CloudKit
/// container in unit tests: local state is ready first, then the first sync
/// pass begins.
enum MacSyncBootstrap {
    @MainActor
    static func run(
        local: @escaping @MainActor () async -> Void,
        sync: @escaping @MainActor () async -> Void
    ) async {
        await local()
        await sync()
    }
}
