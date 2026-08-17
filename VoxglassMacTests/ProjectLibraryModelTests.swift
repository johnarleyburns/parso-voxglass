import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

@MainActor
@Suite struct ProjectLibraryModelTests {

    @Test func createsNewProjectWithGivenMetadata() {
        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        let model = ProjectLibraryModel(store: store, recents: recents)

        let project = model.newProject(
            title: "Test Book",
            author: "Test Author",
            narrator: "Test Narrator",
            purpose: .personal,
            destination: .librivox
        )

        #expect(project.metadata.title == "Test Book")
        #expect(project.metadata.author == "Test Author")
        #expect(project.metadata.narrator == "Test Narrator")
        #expect(project.profile.purpose == .personal)
        #expect(project.profile.intendedDestination == .librivox)
        #expect(project.chapters.isEmpty)
    }

    @Test func createAndPersistWritesRealPackage() async throws {
        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        recents.clear()
        let model = ProjectLibraryModel(store: store, recents: recents)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectURL = tempDir.appendingPathComponent("created.voxproject")

        let project = try await model.createAndPersistProject(
            title: "Persisted", author: "A", narrator: "N",
            purpose: .personal, destination: .librivox,
            at: projectURL
        )

        #expect(project.metadata.title == "Persisted")
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("project.sqlite").path))
        #expect(recents.recentURLs.first?.lastPathComponent == "created.voxproject")

        let reopened = try await ProjectPackage.open(projectURL)
        #expect(reopened.root.path == projectURL.path)
    }

    @Test func openedPackageReloadsSavedProject() async throws {
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        recents.clear()
        let model = ProjectLibraryModel(store: InMemoryProductionStore(), recents: recents)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectURL = tempDir.appendingPathComponent("reload.voxproject")

        _ = try await model.createAndPersistProject(
            title: "Reload Me", author: "A", narrator: "N",
            purpose: .personal, destination: .librivox,
            at: projectURL
        )

        await model.openProject(at: projectURL)

        #expect(model.pendingProjectURL?.path == projectURL.path)
        #expect(recents.recentURLs.first?.lastPathComponent == "reload.voxproject")
        #expect(model.error == nil)
    }

    @Test func openThrowsForInvalidPackage() async {
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        let model = ProjectLibraryModel(store: InMemoryProductionStore(), recents: recents)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fakeURL = tempDir.appendingPathComponent("fake.voxproject")
        try? FileManager.default.createDirectory(at: fakeURL, withIntermediateDirectories: true)

        await model.openProject(at: fakeURL)

        #expect(model.error != nil)
    }

    @Test func recentProjectLimitEnforced() {
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        recents.clear()

        for i in 0..<35 {
            let url = URL(fileURLWithPath: "/projects/test\(i).voxproject")
            recents.add(url: url, manifest: nil, summary: nil)
        }

        #expect(recents.recentURLs.count <= 30)
        #expect(recents.recentURLs.first?.lastPathComponent == "test34.voxproject")
    }

    @Test func seedEmptyClearsRecents() async {
        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        recents.clear()

        for i in 0..<3 {
            recents.add(url: URL(fileURLWithPath: "/projects/test\(i).voxproject"), manifest: nil, summary: nil)
        }
        #expect(recents.recentURLs.count == 3)

        let model = ProjectLibraryModel(
            store: store,
            recents: recents,
            seed: .empty,
            isTestEnvironment: true
        )
        await model.seedIfNeeded()

        #expect(recents.recentURLs.isEmpty)
    }

    @Test func seedIsNoopOutsideTestEnvironment() async {
        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        recents.clear()

        for i in 0..<3 {
            recents.add(url: URL(fileURLWithPath: "/projects/test\(i).voxproject"), manifest: nil, summary: nil)
        }
        let countBefore = recents.recentURLs.count

        let model = ProjectLibraryModel(
            store: store,
            recents: recents,
            seed: .empty,
            isTestEnvironment: false
        )
        await model.seedIfNeeded()

        #expect(recents.recentURLs.count == countBefore)
    }

    @Test func newProjectPassesNarratorAsIs() {
        let store = InMemoryProductionStore()
        let model = ProjectLibraryModel(store: store, recents: RecentsStore(storageDirectory: URL.temporaryDirectory))

        let project = model.newProject(
            title: "Book",
            author: "Author",
            narrator: "Custom Narrator",
            purpose: .personal,
            destination: .librivox
        )

        #expect(project.metadata.narrator == "Custom Narrator")
    }
}
