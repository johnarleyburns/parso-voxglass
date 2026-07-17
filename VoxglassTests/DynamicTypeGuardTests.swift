import XCTest
@testable import VoxglassCore

/// Source-level guard (P2-3): fails the suite if any SwiftUI file still uses a
/// bare `.font(.system(size:)` instead of `.scaledFont(size:)`. The one
/// exception is `ScaledFontModifier.swift` which is the implementation of
/// `scaledFont`.
final class DynamicTypeGuardTests: XCTestCase {

    func testNoBareSystemSizeWithoutScaledFont() throws {
        var violations: [String] = []
        for line in try swiftSourceLines() where line.file != "ScaledFontModifier.swift" {
            if line.text.contains(".font(.system(") && line.text.contains("size:") {
                violations.append("\(line.file):\(line.number)")
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

    func testCompactBookRowsDoNotUseFixedTopPinnedLayout() throws {
        let disallowed = [
            "BookRowMetrics",
            ".lineLimit(2, reservesSpace: true)",
            ".frame(maxHeight: .infinity, alignment: .top)"
        ]
        var violations: [String] = []
        for line in try swiftSourceLines() {
            if disallowed.contains(where: { line.text.contains($0) }) {
                violations.append("\(line.file):\(line.number)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Compact book/result rows must be vertically centered and content-driven:
            \(violations.joined(separator: "\n"))
            Use `BookListRow` with `minHeight`, no reserved title space, and no top-pinned text stack.
            """
        )
    }

    func testNoNegativeKerningInSwiftUISources() throws {
        var violations: [String] = []
        for line in try swiftSourceLines() where line.text.contains(".kerning(-") {
            violations.append("\(line.file):\(line.number)")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Negative letter spacing undermines Dynamic Type and system typography:
            \(violations.joined(separator: "\n"))
            Prefer the platform font metrics without tightening.
            """
        )
    }

    private func swiftSourceLines() throws -> [(file: String, number: Int, text: String)] {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourcesDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Voxglass")

        let enumerator = FileManager.default.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var sourceLines: [(file: String, number: Int, text: String)] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                sourceLines.append((fileURL.lastPathComponent, index + 1, line))
            }
        }
        return sourceLines
    }
}
