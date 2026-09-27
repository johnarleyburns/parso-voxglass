import CarPlay

/// The single gate for `CPSearchTemplate`.
///
/// Apple's CarPlay Developer Guide (June 2026, "Templates" table) lists the
/// Search template for the Audio/video app category as supported only on
/// **iOS 27 or later**. "Each CarPlay app category supports specific templates
/// and this is governed by the app entitlement. Attempting to use an
/// unsupported template triggers an exception at runtime." On iOS 18 that
/// exception is `CPAssertAllowedClasses` inside `pushTemplate` — an
/// Objective-C exception Swift cannot catch, which is the in-car crash this
/// type exists to prevent. Every search entry point must pass through here;
/// `CarPlaySearchGateContractTests` pins that. The app now has an iOS 27
/// deployment floor, so this remains a named policy seam without a dead
/// runtime availability branch.
enum CarPlaySearchAvailability {
    static let templateSupported = true
}
