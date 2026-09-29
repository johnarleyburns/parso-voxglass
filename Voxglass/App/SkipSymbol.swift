import VoxglassCore

/// SF Symbol names for the skip controls. Resolving a numbered symbol
/// (`gobackward.45`) requires UIKit to check availability, so this lives in the
/// app layer rather than in the platform-free playback core. The allowed values
/// themselves are `PlaybackCoordinator.allowedSkip{Back,Forward}Values`.
enum SkipSymbol {
    static func back(_ seconds: Int) -> String {
        SkipSymbols.back(seconds)
    }

    static func forward(_ seconds: Int) -> String {
        SkipSymbols.forward(seconds)
    }
}
