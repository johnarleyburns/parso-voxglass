import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

@MainActor
@Suite struct NewProjectModelTests {

    @Test func canProceedWhenFieldsPopulated() {
        let model = NewProjectModel()
        #expect(model.canProceed == false)

        model.title = "The Great Book"
        #expect(model.canProceed == false)

        model.author = "Jane Doe"
        #expect(model.canProceed == true)
    }

    @Test func canProceedFalseForWhitespaceOnly() {
        let model = NewProjectModel()
        model.title = "   "
        model.author = "Author"
        #expect(model.canProceed == false)

        model.title = "Title"
        model.author = "   "
        #expect(model.canProceed == false)
    }

    @Test func defaultValues() {
        let model = NewProjectModel()
        #expect(model.language == "en")
        #expect(model.purpose == .personal)
        #expect(model.destination == .librivox)
        #expect(model.title.isEmpty)
        #expect(model.author.isEmpty)
        #expect(model.narrator.isEmpty)
        #expect(model.createdProject == nil)
    }

    @Test func createProjectPersistsToPackage() async throws {
        let model = NewProjectModel()
        model.title = "My Book"
        model.author = "Author Name"
        model.narrator = "Voice Actor"

        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        let library = ProjectLibraryModel(store: store, recents: recents)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectURL = tempDir.appendingPathComponent("mybook.voxproject")

        await model.createProject(using: library, at: projectURL)

        #expect(model.createdProject != nil)
        #expect(model.createdProject?.metadata.title == "My Book")
        #expect(model.createdProject?.metadata.author == "Author Name")
        #expect(model.createdProject?.metadata.narrator == "Voice Actor")
        #expect(model.createdProject?.chapters.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("manifest.json").path))
        #expect(model.error == nil)
    }

    @Test func narratorDefaultsWhenEmpty() async throws {
        let model = NewProjectModel()
        model.title = "Book"
        model.author = "Author"
        model.narrator = ""

        let store = InMemoryProductionStore()
        let recents = RecentsStore(storageDirectory: URL.temporaryDirectory)
        let library = ProjectLibraryModel(store: store, recents: recents)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectURL = tempDir.appendingPathComponent("book.voxproject")

        await model.createProject(using: library, at: projectURL)

        #expect(model.createdProject?.metadata.narrator == "Narrator")
    }
}
