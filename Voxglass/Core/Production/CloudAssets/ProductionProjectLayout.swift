import Foundation

/// The user-facing project root is opaque to the user; Files exports are the
/// portable boundary. This helper centralizes the project package directory
/// contract (§4.4): every path rule for a `.voxproject` package is spelled
/// here and nowhere else. The content-addressed subdirectories derive from
/// `AssetSubdirectory` so the layout and the asset store cannot drift apart.
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
    public var originalAudioURL: URL { root.appendingPathComponent(AssetSubdirectory.original.rawValue, isDirectory: true) }
    public var renderAudioURL: URL { root.appendingPathComponent(AssetSubdirectory.render.rawValue, isDirectory: true) }
    public var proxyAudioURL: URL { root.appendingPathComponent(AssetSubdirectory.proxy.rawValue, isDirectory: true) }
    public var sourceTextURL: URL { root.appendingPathComponent(AssetSubdirectory.source.rawValue, isDirectory: true) }
    public var extractedTextURL: URL { root.appendingPathComponent(AssetSubdirectory.extracted.rawValue, isDirectory: true) }
    public var artworkURL: URL { root.appendingPathComponent(AssetSubdirectory.artwork.rawValue, isDirectory: true) }
    public var exportStagingURL: URL { root.appendingPathComponent("Audio/ExportStaging", isDirectory: true) }
    public var exportsURL: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    public var autosaveURL: URL { root.appendingPathComponent("Autosave", isDirectory: true) }
    public var autosaveSessionURL: URL { autosaveURL.appendingPathComponent("session.json") }
    public var autosaveTakesURL: URL { autosaveURL.appendingPathComponent("takes", isDirectory: true) }
    public var trashURL: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    public var tmpURL: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    /// Every directory a fresh package needs, in create order (§4.4).
    public var directories: [URL] {
        [originalAudioURL, renderAudioURL, proxyAudioURL, exportStagingURL,
         sourceTextURL, extractedTextURL, artworkURL, exportsURL,
         autosaveTakesURL, trashURL, tmpURL]
    }

    /// Returns `url` expressed relative to `root` (for example "Audio/Render"),
    /// or nil when `url` is outside the package.
    public func relativePath(of url: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let urlPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath), urlPath.count > rootPath.count + 1 else { return nil }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }
}
