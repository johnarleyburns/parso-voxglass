import Foundation

/// Source of the device's power state, so the policy stays pure and testable.
/// The app target provides the `ProcessInfo`-backed concrete; Core never reads
/// `ProcessInfo` directly.
public protocol PowerModeProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
}

public struct SystemPowerModeProvider: PowerModeProviding, Sendable {
    public init() {}
    public var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

/// P9 hardening (spec §17 P9, "low power"): background work that is expensive
/// (network uploads, remote hydration) is deferred while the device is in Low
/// Power Mode, so a sync pass on a draining battery stays local-only and never
/// churns the radio or the disk. Critical user-invoked work — recording,
/// review, validation, export — is never gated by this policy.
public struct ProductionPowerPolicy: Sendable {
    private let power: any PowerModeProviding

    public init(power: any PowerModeProviding = SystemPowerModeProvider()) {
        self.power = power
    }

    /// True when the phone should skip non-essential iCloud work this pass.
    public var shouldDeferBackgroundSync: Bool {
        power.isLowPowerModeEnabled
    }
}
