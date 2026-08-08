import Foundation
import Testing
import VoxglassCore

/// §4.4: `ProductionProjectLayout` owns the package path rules — the §4.4 tree
/// is spelled exactly once, and `ProjectPackage` derives its paths from it.
@Suite struct ProductionProjectLayoutTests {

    private let root = URL(fileURLWithPath: "/Application Support/ProductionProjects/ABC", isDirectory: true)

    @Test func treeMatchesTheSpecLayout() {
        let layout = ProductionProjectLayout(root: root)
        #expect(layout.databaseURL.lastPathComponent == "project.sqlite")
        #expect(layout.manifestURL.lastPathComponent == "manifest.json")
        #expect(layout.originalAudioURL.relativePath.hasSuffix("Audio/Original"))
        #expect(layout.renderAudioURL.relativePath.hasSuffix("Audio/Render"))
        #expect(layout.proxyAudioURL.relativePath.hasSuffix("Audio/Proxy"))
        #expect(layout.exportStagingURL.relativePath.hasSuffix("Audio/ExportStaging"))
        #expect(layout.sourceTextURL.relativePath.hasSuffix("Text/source"))
        #expect(layout.extractedTextURL.relativePath.hasSuffix("Text/extracted"))
        #expect(layout.artworkURL.relativePath.hasSuffix("Artwork"))
        #expect(layout.autosaveSessionURL.lastPathComponent == "session.json")
        #expect(layout.autosaveTakesURL.relativePath.hasSuffix("Autosave/takes"))
        #expect(layout.trashURL.lastPathComponent == "Trash")
    }

    @Test func applicationSupportInitPlacesProjectsUnderProductionProjects() {
        let appSupport = URL(fileURLWithPath: "/Application Support", isDirectory: true)
        let layout = ProductionProjectLayout(applicationSupport: appSupport, projectID: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!)
        #expect(layout.root.relativePath == "/Application Support/ProductionProjects/A1B2C3D4-0000-0000-0000-000000000000")
    }

    @Test func directoriesCoversTheCreateTree() {
        let layout = ProductionProjectLayout(root: root)
        let relative = Set(layout.directories.compactMap { layout.relativePath(of: $0) })
        let expected: Set<String> = [
            "Audio/Original", "Audio/Render", "Audio/Proxy", "Audio/ExportStaging",
            "Text/source", "Text/extracted", "Artwork", "Exports",
            "Autosave/takes", "Trash", "tmp"
        ]
        #expect(relative == expected)
    }

    @Test func relativePathReturnsNilOutsideThePackage() {
        let layout = ProductionProjectLayout(root: root)
        #expect(layout.relativePath(of: root.appendingPathComponent("Audio/Render")) == "Audio/Render")
        #expect(layout.relativePath(of: URL(fileURLWithPath: "/elsewhere/x")) == nil)
    }

    @Test func projectPackageDerivesPathsFromLayout() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-wiring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let layout = ProductionProjectLayout(root: tmp)
        let pkg = try await ProjectPackage.create(
            title: "Layout", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )
        #expect(pkg.manifestURL == layout.manifestURL)
        #expect(pkg.databaseURL == layout.databaseURL)
        #expect(pkg.autosaveTakesDirectory == layout.autosaveTakesURL)
        #expect(pkg.autosaveSessionFileURL == layout.autosaveSessionURL)
    }
}
