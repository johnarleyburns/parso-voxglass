// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxglassCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "VoxglassCore", targets: ["VoxglassCore"]),
        .library(name: "VoxglassCoreTestSupport", targets: ["VoxglassCoreTestSupport"]),
        .library(name: "VoxglassEncoders", targets: ["VoxglassEncoders"])
    ],
    targets: [
        .target(
            name: "VoxglassRing",
            path: "VoxglassRing"
        ),
        .target(
            name: "VoxglassCore",
            dependencies: ["VoxglassRing"],
            path: "Voxglass/Core",
            exclude: ["Encoders"],
            resources: [
                .process("Resources/CuratedLists"),
                .copy("Production/Discovery/Resources/needs-seed.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency")
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
            dependencies: ["VoxglassCore"],
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
            dependencies: ["VoxglassCore", "VoxglassCoreTestSupport", "VoxglassEncoders"],
            path: "VoxglassTests",
            exclude: ["Info.plist", "Performance"],
            resources: [.copy("Fixtures/ReplayGain")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VoxglassPerformanceTests",
            dependencies: ["VoxglassCore", "VoxglassCoreTestSupport"],
            path: "VoxglassTests/Performance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
