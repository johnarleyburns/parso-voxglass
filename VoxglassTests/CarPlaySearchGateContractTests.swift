import Foundation
import Testing

/// Source contract for the in-car search crash.
///
/// Apple's CarPlay Developer Guide (June 2026, "Templates" table) allows the
/// Search template for Audio apps only on iOS 27 or later; on earlier iOS
/// `pushTemplate(CPSearchTemplate)` raises an uncatchable Objective-C
/// exception (`CPAssertAllowedClasses`). The app target is not compiled by
/// `swift test`, so these checks read the source text: exactly one place may
/// construct the template, and it must sit behind `CarPlaySearchAvailability`.
@Suite struct CarPlaySearchGateContractTests {
    private static let dispatcherPath = "Voxglass/App/CarPlay/CarPlayActionDispatcher.swift"
    private static let availabilityPath = "Voxglass/App/CarPlay/CarPlaySearchAvailability.swift"

    @Test func searchTemplateIsConstructedInExactlyOneFile() throws {
        let offenders = try swiftFiles(under: ["Voxglass", "VoxglassMac"])
            .filter { try source($0).contains("CPSearchTemplate(") }
        #expect(offenders == [Self.dispatcherPath])
    }

    @Test func searchTemplateConstructionIsBehindTheAvailabilityGate() throws {
        let dispatcher = try source(Self.dispatcherPath)
        let gate = try #require(dispatcher.range(of: "guard CarPlaySearchAvailability.templateSupported"))
        let construction = try #require(dispatcher.range(of: "CPSearchTemplate("))
        #expect(gate.lowerBound < construction.lowerBound)
    }

    @Test func availabilityGateIsIOS27() throws {
        let availability = try source(Self.availabilityPath)
        #expect(availability.contains("#available(iOS 27.0, *)"))
    }

    @Test func tabBarNeverReceivesASearchTemplate() throws {
        for path in try swiftFiles(under: ["Voxglass"]) {
            for line in try source(path).split(separator: "\n") where line.contains("CPTabBarTemplate(") {
                #expect(!line.contains("CPSearchTemplate"), "\(path): \(line)")
            }
        }
    }

    // MARK: - Helpers

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Repo-relative paths of every `.swift` file under the given directories,
    /// sorted for a stable comparison.
    private func swiftFiles(under directories: [String]) throws -> [String] {
        let root = repoRoot.resolvingSymlinksInPath().path
        var paths: [String] = []
        for directory in directories {
            let base = repoRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root + "/") else { continue }
                paths.append(String(path.dropFirst(root.count + 1)))
            }
        }
        return paths.sorted()
    }
}
