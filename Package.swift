// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxglassCore",
    defaultLocalization: "en",
    // SwiftPM tests execute on the macOS CI host. This does not ship or build
    // a native macOS Voxglass application; that target has been removed.
    platforms: [.iOS("26.0"), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "VoxglassCore", targets: ["VoxglassCore"]),
        .library(name: "VoxglassWatchProtocol", targets: ["VoxglassWatchProtocol"]),
        .library(name: "VoxglassWatchCore", targets: ["VoxglassWatchCore"])
    ],
    dependencies: [
        // Audio-engine unification (parso-audio-engine/docs/UNIFICATION_PLAN.md).
        // Consume the published release so local and CI builds validate the same
        // immutable engine revision.
        .package(
            url: "https://github.com/johnarleyburns/parso-audio-engine.git",
            exact: "1.2.2"
        )
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
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine"),
                .product(name: "ParsoAudioPlayback", package: "parso-audio-engine")
            ],
            path: "Voxglass/Core",
            exclude: ["Encoders"],
            resources: [
                .process("Resources/CuratedLists"),
                .process("Resources/Localizable.xcstrings")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "collection-counts",
            dependencies: ["VoxglassCore"],
            path: "Tools/CollectionCounts"
        ),
        .executableTarget(
            name: "librivox-languages",
            dependencies: ["VoxglassCore"],
            path: "Tools/LibriVoxLanguages"
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
                "VoxglassCore",
                "VoxglassWatchProtocol", "VoxglassWatchCore",
                .product(name: "ParsoAudioStreaming", package: "parso-audio-engine"),
                .product(name: "ParsoAudioPlayback", package: "parso-audio-engine")
            ],
            path: "VoxglassTests",
            exclude: ["Info.plist", "Performance"],
            resources: [
                .copy("Fixtures/ReplayGain"),
                .copy("Fixtures/InternetArchive"),
                .copy("Fixtures/LibriVox"),
                .copy("Fixtures/EPUB"),
                .copy("Fixtures/AuthoringV2")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
