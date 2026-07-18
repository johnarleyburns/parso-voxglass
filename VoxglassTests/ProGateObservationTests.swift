import XCTest

/// Drift guard: every SwiftUI view with a `ProFeature.isEnabled(...)` gate must
/// also observe `StoreManager.shared` so `isPro` publishing triggers re-render.
final class ProGateObservationTests: XCTestCase {

    func testEveryGatedSwiftUIViewObservesStoreManager() throws {
        let gatedFileURLs = try gatedSwiftUIFiles()
        var missingObservation: [String] = []

        for fileURL in gatedFileURLs {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            if !contents.contains("StoreManager.shared") {
                missingObservation.append(fileURL.lastPathComponent)
            }
        }

        XCTAssertTrue(
            missingObservation.isEmpty,
            "SwiftUI views with ProFeature.isEnabled gates must observe StoreManager.shared: \(missingObservation.joined(separator: ", "))"
        )
    }

    // MARK: - Helpers

    private func gatedSwiftUIFiles() throws -> [URL] {
        let root = sourcesRoot()
        let dirs = ["Features", "DesignSystem"]
        var result: [URL] = []

        for dir in dirs {
            let dirURL = root.appendingPathComponent(dir)
            let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                if contents.contains("ProFeature.isEnabled(") {
                    result.append(fileURL)
                }
            }
        }

        return result
    }

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Voxglass")
    }
}
