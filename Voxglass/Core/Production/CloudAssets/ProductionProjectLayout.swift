import Foundation

/// The user-facing project root is opaque to the user; Files exports are the
/// portable boundary. This helper centralizes the iPhone directory contract.
public struct ProductionProjectLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public init(applicationSupport: URL, projectID: UUID) {
        self.root = applicationSupport
            .appendingPathComponent("ProductionProjects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    public var databaseURL: URL { root.appendingPathComponent("project.sqlite") }
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public var originalAudioURL: URL { root.appendingPathComponent("Audio/Original", isDirectory: true) }
    public var renderAudioURL: URL { root.appendingPathComponent("Audio/Render", isDirectory: true) }
    public var exportStagingURL: URL { root.appendingPathComponent("Audio/ExportStaging", isDirectory: true) }
    public var sourceTextURL: URL { root.appendingPathComponent("Text/source", isDirectory: true) }
    public var extractedTextURL: URL { root.appendingPathComponent("Text/extracted", isDirectory: true) }
    public var artworkURL: URL { root.appendingPathComponent("Artwork", isDirectory: true) }
    public var autosaveURL: URL { root.appendingPathComponent("Autosave", isDirectory: true) }
    public var trashURL: URL { root.appendingPathComponent("Trash", isDirectory: true) }
}
