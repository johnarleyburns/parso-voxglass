import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// §17.3 + §19.3 "License" suite. These tests prove the gate semantics: what
/// `require(_:)` throws, what `isUnlocked(_:)` returns per entitlement, that a
/// single gate check reads entitlement exactly once, and that a revoked
/// entitlement reverts. The "free export paths never consult the gate" proof
/// lives in `LicenseGatePlacementTests` below — the §2.2 placement enforcement
/// (grep for `LicenseGate`/`isPro` references outside the permitted files).
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

/// §2.2 — placement enforcement. "LicenseGate appears in exactly three places —
/// the export destination picker, the export runner, and Settings." Verbatim:
/// "greps the built source set for `LicenseGate`/`isPro` references outside the
/// three permitted files and fails on any other occurrence."
///
/// The permitted set is the three surfaces (§2.2), the StoreKit concrete that
/// supplies the entitlement (added by §13.5/P8: `StoreKitLicenseProvider`,
/// `NarrationProStore`, `ProPurchaseView`), and the two Core files that
/// *define* the types (`LicenseTypes`, `EntitlementCache`) — definitions are
/// not consultations. The list is explicit so a new file cannot silently join
/// it; the gate-consulting surfaces are the destination picker, the export
/// runner, and Settings, and nowhere else.
@Suite struct LicenseGatePlacementTests {

    /// Files allowed to reference `LicenseGate`/`isPro`. Everything else in the
    /// app and watch sources must be clean — recording, review, validation,
    /// assembly, storage, and watch code never consult the gate (§2.2).
    private static let permittedPaths: [String] = [
        // Core definitions (the types themselves, not consultations).
        "Core/Production/License/LicenseTypes.swift",
        "Core/Production/License/EntitlementCache.swift",
        // The three §2.2 surfaces: destination picker, export runner, Settings.
        "Features/Production/Discovery/NarrationFlowScreens.swift",
        "Features/Production/Discovery/NarrationFlow.swift",
        "Features/Settings/SettingsView.swift",
        // The StoreKit concrete (entitlement mechanism, §13.5 P8).
        "Features/Production/StoreKitLicenseProvider.swift",
        "Features/Production/NarrationProStore.swift",
        "Features/Production/ProPurchaseView.swift"
    ]

    @Test func gateReferencesOnlyInPermittedFiles() throws {
        var violations: [String] = []
        for area in ["Voxglass", "VoxglassWatch"] {
            let root = URL(fileURLWithPath: area, relativeTo: repositoryRoot())
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                if permittedPath(relative) { continue }
                let content = try String(contentsOf: file, encoding: .utf8)
                let lines = content.split(separator: "\n")
                for (index, line) in lines.enumerated() {
                    if line.contains("LicenseGate") || line.contains("isPro") {
                        violations.append("\(area)/\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(
            violations.isEmpty,
            "LicenseGate/isPro must appear only in the permitted files (§2.2):\n\(violations.joined(separator: "\n"))"
        )
    }

    private func permittedPath(_ relative: String) -> Bool {
        Self.permittedPaths.contains { relative.hasSuffix($0) }
    }

    private func repositoryRoot() -> URL {
        // The test runs from the package root; walk up from the current
        // directory until a directory containing both Voxglass/ and VoxglassWatch/
        // is found, so the test works from any SwiftPM working directory.
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Voxglass").path)
            || !FileManager.default.fileExists(atPath: url.appendingPathComponent("VoxglassWatch").path) {
            let parent = url.deletingLastPathComponent()
            if parent == url {
                Issue.record("Could not locate repository root from \(FileManager.default.currentDirectoryPath)")
                return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }
            url = parent
        }
        return url
    }
}
