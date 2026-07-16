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
            exclude: ["Info.plist"]
        )
    ]
)
