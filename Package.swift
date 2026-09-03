// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxglassCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "VoxglassCore", targets: ["VoxglassCore"]),
        .library(name: "VoxglassWatchProtocol", targets: ["VoxglassWatchProtocol"]),
        .library(name: "VoxglassWatchCore", targets: ["VoxglassWatchCore"]),
        .library(name: "VoxglassCoreTestSupport", targets: ["VoxglassCoreTestSupport"]),
        .library(name: "VoxglassEncoders", targets: ["VoxglassEncoders"])
    ],
    dependencies: [
        // Audio-engine unification (parso-audio-engine/docs/UNIFICATION_PLAN.md).
        // Local path override on the migration branch; swaps to a version tag on
        // merge. Requires parso-audio-engine checked out as a sibling directory.
        .package(path: "../parso-audio-engine")
    ],
    targets: [
        .target(
            name: "VoxglassWatchProtocol",
            path: "VoxglassWatchProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoxglassWatchCore",
            dependencies: ["VoxglassWatchProtocol"],
            path: "VoxglassWatchCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoxglassRing",
            path: "VoxglassRing"
        ),
        .target(
            name: "VoxglassCore",
            dependencies: [
                "VoxglassRing", "VoxglassWatchProtocol", "VoxglassWatchCore",
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine")
            ],
            path: "Voxglass/Core",
            exclude: ["Encoders"],
            resources: [
                .process("Resources/CuratedLists"),
                .copy("Production/Discovery/Resources/needs-seed.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .binaryTarget(
            name: "Lame",
            path: "Tools/encoders/Vendored/Lame.xcframework"
        ),
        .binaryTarget(
            name: "FLAC",
            path: "Tools/encoders/Vendored/FLAC.xcframework"
        ),
        .target(
            name: "VoxglassEncoders",
            dependencies: ["VoxglassCore", "Lame", "FLAC"],
            path: "Voxglass/Core/Encoders",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoxglassCoreTestSupport",
            dependencies: [
                "VoxglassCore",
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine")
            ],
            path: "VoxglassCoreTestSupport",
            resources: [.copy("Fixtures/Schemas")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "collection-counts",
            dependencies: ["VoxglassCore"],
            path: "Tools/CollectionCounts"
        ),
        .executableTarget(
            name: "curated-lists",
            dependencies: ["VoxglassCore"],
            path: "Tools/CuratedLists",
            exclude: [
                "creator-aliases.json",
                "extract_workbook.py",
                "gbww-works.json",
                "generate_greater_books.py",
                "great-books-source.csv",
                "greater-books-creator-aliases.json",
                "greater-books-source.csv",
                "greater-books-works.json",
                "__pycache__",
                "out",
                "probe_creator_aliases.py",
                "verified-seed.json"
            ]
        ),
        .testTarget(
            name: "VoxglassCoreTests",
            dependencies: [
                "VoxglassCore", "VoxglassCoreTestSupport", "VoxglassEncoders",
                "VoxglassWatchProtocol", "VoxglassWatchCore",
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine")
            ],
            path: "VoxglassTests",
            exclude: ["Info.plist", "Performance"],
            resources: [
                .copy("Fixtures/ReplayGain"),
                .copy("Fixtures/InternetArchive"),
                .copy("Fixtures/LibriVox")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoxglassPerformanceTests",
            dependencies: ["VoxglassCore", "VoxglassCoreTestSupport"],
            path: "VoxglassTests/Performance",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
