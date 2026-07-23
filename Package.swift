// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoxglassCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "VoxglassCore", targets: ["VoxglassCore"])
    ],
    targets: [
        .target(
            name: "VoxglassCore",
            path: "Voxglass/Core",
            resources: [.process("Resources/CuratedLists")],
            linkerSettings: [.linkedLibrary("sqlite3")]
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
            dependencies: ["VoxglassCore"],
            path: "VoxglassTests",
            exclude: ["Info.plist"]
        )
    ]
)
