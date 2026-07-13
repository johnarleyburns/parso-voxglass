import XCTest
@testable import Voxglass

/// Source-level guard (P2-3): fails the suite if any SwiftUI file still uses a
/// bare `Font.system(size:)` without `relativeTo:`. Also usable as a CI check.
final class DynamicTypeGuardTests: XCTestCase {

    func testNoBareSystemSizeWithoutRelativeTo() throws {
        // Walk the Voxglass sources in the repo (not the built product) so we can
        // grep the Swift files rather than relying on compiled symbol metadata.
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
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where
                line.contains("Font.system(") &&
                line.contains("size:") &&
                !line.contains("relativeTo:") {
                violations.append("\(fileURL.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Bare `Font.system(size:)` without `relativeTo:` in:
            \(violations.joined(separator: "\n"))
            Use `.system(size: X, relativeTo: .body)` or a semantic style so Dynamic Type works.
            """
        )
    }
}
