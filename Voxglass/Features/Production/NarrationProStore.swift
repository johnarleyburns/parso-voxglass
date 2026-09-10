import Foundation
import VoxglassCore

/// There is no paid Narration Pro tier any more — every commercial-export
/// feature (retail presets, mastering, M4B, FLAC, batch export, exportable
/// validation reports) is free. This still hands out a `LicenseProvider`
/// pinned to `.pro` so `NarrationFlow`'s existing `licenseGate`/
/// `isProUnlocked` call sites keep working unchanged and never gate
/// anything — see `LicenseTypes.swift`. Purchasing is now
/// `SupportDevelopmentStore`'s optional, non-gating consumable.
@MainActor
final class NarrationProStore {
    static let shared = NarrationProStore()

    let provider: any LicenseProvider
    var gate: LicenseGate { LicenseGate(provider: provider) }

    init(provider: any LicenseProvider = StaticLicenseProvider(entitlement: .pro(since: .distantPast))) {
        self.provider = provider
    }
}
