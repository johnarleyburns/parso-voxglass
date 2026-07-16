import XCTest
@testable import VoxglassCore

/// Source-level guard (P2-3): fails the suite if any SwiftUI file still uses a
/// bare `.font(.system(size:)` instead of `.scaledFont(size:)`. The one
/// exception is `ScaledFontModifier.swift` which is the implementation of
/// `scaledFont`.
final class DynamicTypeGuardTests: XCTestCase {

    func testNoBareSystemSizeWithoutScaledFont() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourcesDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Voxglass")

        let enumerator = FileManager.default.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var violations: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            guard fileURL.lastPathComponent != "ScaledFontModifier.swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where
                line.contains(".font(.system(") &&
                line.contains("size:") {
                violations.append("\(fileURL.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Bare `.font(.system(size:)` without Dynamic Type support in:
            \(violations.joined(separator: "\n"))
            Use `.scaledFont(size: X)` (adds `@ScaledMetric`) so Dynamic Type works.
            """
        )
    }
}
