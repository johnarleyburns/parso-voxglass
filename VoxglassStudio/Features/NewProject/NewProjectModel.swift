import Foundation
import Observation
import VoxglassCore

@MainActor
@Observable
public final class NewProjectModel {
    public var title = ""
    public var author = ""
    public var narrator = ""
    public var language = "en"
    public var purpose: ProjectPurpose = .personal
    public var destination: DestinationID = .librivox
    public private(set) var createdProject: AudiobookProject?
    public private(set) var error: String?

    public var canProceed: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !author.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init() {}

    public func createProject(using library: ProjectLibraryModel, at directory: URL) async {
        do {
            createdProject = try await library.createAndPersistProject(
                title: title.trimmingCharacters(in: .whitespaces),
                author: author.trimmingCharacters(in: .whitespaces),
                narrator: narrator.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Narrator" : narrator.trimmingCharacters(in: .whitespaces),
                purpose: purpose,
                destination: destination,
                at: directory
            )
            error = nil
        } catch {
            self.error = "Failed to create project: \(error.localizedDescription)"
        }
    }

    public func dismissError() {
        error = nil
    }
}
