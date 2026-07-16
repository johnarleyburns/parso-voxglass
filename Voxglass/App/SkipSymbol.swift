import UIKit
import VoxglassCore

/// SF Symbol names for the skip controls. Resolving a numbered symbol
/// (`gobackward.45`) requires UIKit to check availability, so this lives in the
/// app layer rather than in the platform-free playback core. The allowed values
/// themselves are `PlaybackCoordinator.allowedSkip{Back,Forward}Values`.
enum SkipSymbol {
    static func back(_ seconds: Int) -> String {
        UIImage(systemName: "gobackward.\(seconds)") != nil
            ? "gobackward.\(seconds)"
            : "gobackward.15"
    }

    static func forward(_ seconds: Int) -> String {
        UIImage(systemName: "goforward.\(seconds)") != nil
            ? "goforward.\(seconds)"
            : "goforward.30"
    }
}
