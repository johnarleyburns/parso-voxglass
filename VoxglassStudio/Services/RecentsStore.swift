import Foundation
import Observation
import VoxglassCore

/// One library row (§8.1): a security-scoped bookmark plus the cached
/// manifest and counts so the sidebar renders without opening any database.
public struct RecentProject: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var bookmark: Data
    public var lastKnownURL: URL
    public var manifest: PackageManifest?
    public var summarySnapshot: ProjectSummary?
    public var lastOpenedAt: Date

    public init(
        id: UUID,
        bookmark: Data,
        lastKnownURL: URL,
        manifest: PackageManifest? = nil,
        summarySnapshot: ProjectSummary? = nil,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownURL = lastKnownURL
        self.manifest = manifest
        self.summarySnapshot = summarySnapshot
        self.lastOpenedAt = lastOpenedAt
    }
}

@MainActor
@Observable
public final class RecentsStore {
    public private(set) var projects: [RecentProject] = []

    public var recentURLs: [URL] { projects.map(\.lastKnownURL) }

    private let storageURL: URL

    public init(storageDirectory: URL? = nil) {
        let dir: URL
        if let explicitDir = storageDirectory {
            dir = explicitDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("guru.parso.voxglass.studio")
        }
        self.storageURL = dir.appendingPathComponent("recents.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = load()
    }

    /// Registers an opened project, refreshing its manifest and snapshot.
    public func add(url: URL, manifest: PackageManifest?, summary: ProjectSummary?) {
        var bookmark = Data()
        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        }
        let entry = RecentProject(
            id: manifest?.projectID ?? Self.stableID(for: url),
            bookmark: bookmark,
            lastKnownURL: url,
            manifest: manifest,
            summarySnapshot: summary,
            lastOpenedAt: Date()
        )
        var projects = self.projects
        projects.removeAll { $0.lastKnownURL.absoluteString == url.absoluteString || $0.id == entry.id }
        projects.insert(entry, at: 0)
        if projects.count > 30 {
            projects = Array(projects.prefix(30))
        }
        self.projects = projects
        save()
    }

    /// Refreshes the cached snapshot for an opened project (on close and
    /// after any sync fetch, §8.1).
    public func updateSummary(_ summary: ProjectSummary, forURL url: URL) {
        guard let index = projects.firstIndex(where: { $0.lastKnownURL.absoluteString == url.absoluteString }) else { return }
        projects[index].summarySnapshot = summary
        projects[index].lastOpenedAt = Date()
        save()
    }

    public func remove(url: URL) {
        projects.removeAll { $0.lastKnownURL.absoluteString == url.absoluteString }
        save()
    }

    public func clear() {
        projects.removeAll()
        save()
    }

    /// Resolves a row's bookmark; nil means "Missing — locate…" (§8.1).
    public func resolvedURL(for project: RecentProject) -> URL? {
        guard !project.bookmark.isEmpty else { return project.lastKnownURL }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: project.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    @discardableResult
    public func load() -> Bool {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return false }
        guard let data = try? Data(contentsOf: storageURL) else { return false }

        if let decoded = try? JSONDecoder().decode(RecentsData.self, from: data), !decoded.projects.isEmpty {
            projects = decoded.projects
            return true
        }
        // Legacy format ({entries:[{bookmark,path}]}) — migrate in place.
        if let legacy = try? JSONDecoder().decode(LegacyRecentsData.self, from: data) {
            var migrated: [RecentProject] = []
            for entry in legacy.entries {
                var isStale = false
                let resolved = entry.bookmark.flatMap {
                    try? URL(resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                }
                guard let url = resolved ?? URL(string: entry.path) else { continue }
                migrated.append(RecentProject(
                    id: Self.stableID(for: url),
                    bookmark: entry.bookmark ?? Data(),
                    lastKnownURL: url,
                    lastOpenedAt: Date()
                ))
            }
            if !migrated.isEmpty {
                projects = migrated
                save()
                return true
            }
        }
        return false
    }

    public func save() {
        let data = try? JSONEncoder().encode(RecentsData(projects: projects))
        if let data {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    /// A deterministic project id from the URL — used only for entries whose
    /// manifest was never read (legacy rows); real rows use the manifest's id.
    public static func stableID(for url: URL) -> UUID {
        let hex = SHA256Hex.hex(Data(url.absoluteString.utf8))
        let prefix = String(hex.prefix(32))
        var formatted = prefix
        formatted.insert("-", at: formatted.index(formatted.startIndex, offsetBy: 8))
        formatted.insert("-", at: formatted.index(formatted.startIndex, offsetBy: 13))
        formatted.insert("-", at: formatted.index(formatted.startIndex, offsetBy: 18))
        formatted.insert("-", at: formatted.index(formatted.startIndex, offsetBy: 23))
        return UUID(uuidString: formatted) ?? UUID()
    }

    private struct RecentsData: Codable {
        var projects: [RecentProject]
    }

    private struct LegacyRecentsData: Codable {
        var entries: [LegacyBookmarkEntry]
    }

    private struct LegacyBookmarkEntry: Codable {
        var bookmark: Data?
        var path: String
    }
}
