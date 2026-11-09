import Foundation

/// Routing for the Handoff activity the Apple Watch advertises ("Continue on iPhone").
/// Kept in a module both app targets already link (unlike `VoxglassCore`, which the watch target
/// never links) so the activity-type → destination mapping is unit-testable without a Handoff
/// session, from either side.
public enum WatchHandoffRoute: Equatable, Sendable {
    /// The iPhone's My Books tab. The watch activity targets the library, never a specific book.
    case library

    public static let activityType = "guru.parso.voxglass.watch.library"

    public static func route(forActivityType type: String) -> WatchHandoffRoute? {
        type == activityType ? .library : nil
    }
}
