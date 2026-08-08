import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// §17.3 + §19.3 "License" suite. These tests prove the gate semantics: what
/// `require(_:)` throws, what `isUnlocked(_:)` returns per entitlement, that a
/// single gate check reads entitlement exactly once, and that a revoked
/// entitlement reverts. The "free export paths never consult the gate" proof
/// lives in `ExportModelTests` (Studio).
@Suite struct LicenseGateTests {

    // MARK: - isUnlocked

    @Test func proEntitlementUnlocksEveryFeature() async {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        let gate = LicenseGate(provider: provider)
        for feature in ProFeature.allCases {
            #expect(await gate.isUnlocked(feature))
        }
    }

    @Test func freeEntitlementLocksEveryFeature() async {
        let provider = FakeLicenseProvider(entitlement: .free)
        let gate = LicenseGate(provider: provider)
        for feature in ProFeature.allCases {
            #expect(await gate.isUnlocked(feature) == false)
        }
    }

    @Test func pendingAndUnknownNeverUnlock() async {
        let pending = FakeLicenseProvider(entitlement: .pending)
        #expect(await LicenseGate(provider: pending).isUnlocked(.retailPresets) == false)

        let unknown = FakeLicenseProvider(entitlement: .unknown)
        #expect(await LicenseGate(provider: unknown).isUnlocked(.retailPresets) == false)
    }

    // MARK: - require

    @Test func requireSucceedsWhenPro() async throws {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        try await LicenseGate(provider: provider).require(.retailPresets)
    }

    @Test func requireThrowsProRequiredForFree() async {
        let provider = FakeLicenseProvider(entitlement: .free)
        let gate = LicenseGate(provider: provider)
        do {
            try await gate.require(.retailPresets)
            Issue.record("Expected LicenseError.proRequired")
        } catch let error as LicenseError {
            #expect(error == .proRequired(.retailPresets))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func requireThrowsForUnknownVerification() async {
        let provider = FakeLicenseProvider(entitlement: .unknown)
        do {
            try await LicenseGate(provider: provider).require(.m4bExport)
            Issue.record("Expected LicenseError.proRequired")
        } catch let error as LicenseError {
            #expect(error == .proRequired(.m4bExport))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Access accounting

    @Test func constructingGateConsultsNothing() async {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        _ = LicenseGate(provider: provider)
        #expect(provider.calls.isEmpty)
    }

    @Test func oneRequireReadsEntitlementExactlyOnce() async throws {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        try await LicenseGate(provider: provider).require(.retailPresets)
        #expect(provider.calls == [.entitlement])
    }

    @Test func isUnlockedReadsEntitlementExactlyOnce() async {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        _ = await LicenseGate(provider: provider).isUnlocked(.flacExport)
        #expect(provider.calls == [.entitlement])
    }

    // MARK: - Revocation (§17.4)

    @Test func revokedEntitlementRevertsToFree() async {
        let provider = FakeLicenseProvider(entitlement: .pro(since: Date(timeIntervalSinceReferenceDate: 0)))
        let gate = LicenseGate(provider: provider)
        #expect(await gate.isUnlocked(.retailPresets))

        // StoreKit reports a refund/revocation: the entitlement flips to free.
        provider.setEntitlement(.free)
        #expect(await gate.isUnlocked(.retailPresets) == false)
    }

    // MARK: - Purchase/restore plumbing

    @Test func purchaseFailurePropagates() async {
        let provider = FakeLicenseProvider(entitlement: .free)
        provider.failNext(.purchaseFailed("store unavailable"))
        do {
            _ = try await provider.purchasePro()
            Issue.record("Expected purchase failure")
        } catch let error as LicenseError {
            #expect(error == .purchaseFailed("store unavailable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(provider.calls.last == .purchase)
    }

    @Test func restoreReturnsEntitlement() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let state = try await provider.restore()
        #expect(state == .free)
        #expect(provider.calls == [.restore])
    }

    @Test func productReturnsInfo() async throws {
        let provider = FakeLicenseProvider(entitlement: .free)
        let info = try await provider.product()
        #expect(info.displayName == NarrationProProduct.displayName)
        #expect(provider.calls == [.product])
    }
}
