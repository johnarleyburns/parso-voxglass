import Foundation
import Testing
@testable import VoxglassCore

/// G-5 enforcement as a Swift Testing suite (CI additionally runs the grep gate in
/// `scripts/guard_production.sh`). Scans the watch target and the Core WatchLink
/// module for any CloudKit import or CK* symbol. When the source tree cannot be
/// located (running from an installed package outside the repo) the test passes
/// without asserting — the CI grep gate remains the authoritative guard there.
@Suite struct WatchNoCloudKitTests {

    private var repoRoot: URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let dir = thisFile.deletingLastPathComponent()   // .../WatchLink
            .deletingLastPathComponent()                 // .../Production
            .deletingLastPathComponent()                 // .../VoxglassTests
            .deletingLastPathComponent()                 // <repo root>
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var result: [URL] = []
        for file in files {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    result.append(contentsOf: try swiftFiles(in: file))
                } else if file.pathExtension == "swift" {
                    result.append(file)
                }
            }
        }
        return result
    }

    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func watchTarget_hasNoCloudKitImportOrSymbol() throws {
        guard let root = repoRoot else { return }
        let watchDir = root.appendingPathComponent("VoxglassWatch")
        guard FileManager.default.fileExists(atPath: watchDir.path) else { return }

        let files = try swiftFiles(in: watchDir)
        #expect(!files.isEmpty, "Expected to find watch sources under \(watchDir.path)")
        let banned = try extractViolations(files: files)
        #expect(
            banned.isEmpty,
            "Watch target must never import or reference CloudKit: \(banned)"
        )
    }

    @Test func coreWatchLinkModule_hasNoCloudKitImportOrSymbol() throws {
        guard let root = repoRoot else { return }
        let moduleDir = root.appendingPathComponent("Voxglass/Core/Production/WatchLink")
        guard FileManager.default.fileExists(atPath: moduleDir.path) else { return }

        let files = try swiftFiles(in: moduleDir)
        #expect(!files.isEmpty, "Expected WatchLink sources under \(moduleDir.path)")
        let banned = try extractViolations(files: files)
        #expect(
            banned.isEmpty,
            "Core WatchLink must never import or reference CloudKit: \(banned)"
        )
    }

    private func extractViolations(files: [URL]) throws -> [String] {
        var violations: [String] = []
        let importPattern = #"import\s+CloudKit"#
        let symbolPattern = #"\bCK[A-Z][A-Za-z0-9]*\b"#
        for file in files {
            guard let content = contents(of: file) else { continue }
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }
                if trimmed.range(of: importPattern, options: .regularExpression) != nil {
                    violations.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
                }
                if trimmed.range(of: symbolPattern, options: .regularExpression) != nil {
                    violations.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        return violations
    }
}
