import Testing
import Foundation
@testable import VoxglassCore

/// Source-level guard (P2-3): fails the suite if any SwiftUI file still uses a
/// bare `.font(.system(size:)` instead of `.scaledFont(size:)`. The one
/// exception is `ScaledFontModifier.swift` which is the implementation of
/// `scaledFont`.
@Suite struct DynamicTypeGuardTests {

    @Test func noBareSystemSizeWithoutScaledFont() throws {
        var violations: [String] = []
        for line in try swiftSourceLines() where line.file != "ScaledFontModifier.swift" {
            if line.text.contains(".font(.system(") && line.text.contains("size:") {
                violations.append("\(line.file):\(line.number)")
            }
        }

        #expect(violations.isEmpty)  // Bare `.font(.system(size:)` without Dynamic Type support; use `.scaledFont(size:)` instead
    }

    @Test func compactBookRowsDoNotUseFixedTopPinnedLayout() throws {
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

        #expect(violations.isEmpty)  // Compact rows must be vertically centered; use BookListRow with minHeight, no top-pinned text stack
    }

    @Test func noNegativeKerningInSwiftUISources() throws {
        var violations: [String] = []
        for line in try swiftSourceLines() where line.text.contains(".kerning(-") {
            violations.append("\(line.file):\(line.number)")
        }

        #expect(violations.isEmpty)  // Negative letter spacing undermines Dynamic Type; prefer platform font metrics
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
