// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxglassCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoxglassCore", targets: ["VoxglassCore"])
    ],
    targets: [
        .target(
            name: "VoxglassCore",
            path: "Voxglass/Core",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "VoxglassCoreTests",
            dependencies: ["VoxglassCore"],
            path: "VoxglassTests",
            exclude: [
                "Info.plist",
                // View/app-coupled tests (SwiftUI views, ArtworkService/UIKit,
                // AppServices, AVPlayerAudioEngine) stay in the app's xcodebuild
                // test target; only pure-logic tests run under `swift test`.
                "ArtworkServiceUnifiedTests.swift",
                "CoverResolutionTests.swift",
                "FreeTierRegistryTests.swift",
                "HomeViewTests.swift",
                "LaunchEntitlementTests.swift",
                "LibriVoxBrowseCategoryTests.swift",
                "NarratorDisplayTests.swift",
                "NowPlayingFavoriteTests.swift",
                "PostFieldTestImprovementsTests.swift",
                "ProPaywallContentTests.swift",
                "ResultRowDetailLineTests.swift",
                "SkipIntervalTests.swift",
                "VisualOnboardingTests.swift",
                // These rely on iOS runtime behavior (AVURLAsset audio decoding;
                // the iOS sqlite3 version for content-key UPSERT) and pass on the
                // simulator, so they run in the app's xcodebuild test target.
                "CloudSyncEntitlementTests.swift",
                "FolderWatchServiceTests.swift"
            ]
        )
    ]
)
