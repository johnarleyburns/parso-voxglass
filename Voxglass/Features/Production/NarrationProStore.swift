import Foundation
import VoxglassCore

/// App-level container for the Narration Pro license (§13.5): owns the StoreKit 2
/// provider and exposes the gate. Core never imports StoreKit; this app-target
/// singleton is the only place a concrete provider is constructed for shipping.
final class NarrationProStore {
    static let shared = NarrationProStore()

    let provider: any LicenseProvider
    var gate: LicenseGate { LicenseGate(provider: provider) }

    init(provider: any LicenseProvider = StoreKitLicenseProvider()) {
        self.provider = provider
    }
}
