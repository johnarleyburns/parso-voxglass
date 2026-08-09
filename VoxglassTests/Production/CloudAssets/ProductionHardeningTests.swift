import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P9 hardening (spec §17 P9, "iCloud quota behavior" and "low power"):
/// `SyncError` produces user-facing copy (so a quota failure reads as "iCloud
/// storage is full" rather than a generic error), and the power policy defers
/// background sync work in Low Power Mode without touching the local fold.
@Suite struct ProductionHardeningTests {

    // MARK: - iCloud quota copy

    @Test func quotaErrorProducesUserFacingCopy() {
        let error = SyncError.quotaExceeded
        let text = error.localizedDescription
        #expect(text.contains("iCloud"))
        #expect(text.contains("full"))
        #expect(!text.contains("The operation couldn"))
    }

    @Test func transientAndAuthErrorsStillLocalize() {
        #expect(!(SyncError.transient(reason: "Network went away", retryAfterSeconds: 5).errorDescription ?? "").isEmpty)
        #expect(!(SyncError.auth.errorDescription ?? "").isEmpty)
        #expect(!(SyncError.transport("boom").errorDescription ?? "").isEmpty)
    }

    // MARK: - Low power

    private struct FailingPower: PowerModeProviding {
        var isLowPowerModeEnabled: Bool { true }
    }

    private struct HealthyPower: PowerModeProviding {
        var isLowPowerModeEnabled: Bool { false }
    }

    @Test func lowPowerModeDefersBackgroundSync() {
        #expect(ProductionPowerPolicy(power: FailingPower()).shouldDeferBackgroundSync)
    }

    @Test func normalPowerDoesNotDefer() {
        #expect(!ProductionPowerPolicy(power: HealthyPower()).shouldDeferBackgroundSync)
    }

    /// Default provider reads the real system state and is never nil-driven.
    @Test func defaultProviderIsSystemBacked() {
        let policy = ProductionPowerPolicy()
        #expect(policy.shouldDeferBackgroundSync == ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
