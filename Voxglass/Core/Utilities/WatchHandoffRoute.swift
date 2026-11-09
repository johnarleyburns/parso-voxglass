import Foundation

/// Routing for the Handoff activity the Apple Watch advertises ("Continue on iPhone").
/// Kept in Core so the activity-type → destination mapping is unit-testable without a Handoff session.
public enum WatchHandoffRoute: Equatable, Sendable {
    /// The iPhone's My Books tab. The watch activity targets the library, never a specific book.
    case library

    public static let activityType = "guru.parso.voxglass.watch.library"

    public static func route(forActivityType type: String) -> WatchHandoffRoute? {
        type == activityType ? .library : nil
    }
}
