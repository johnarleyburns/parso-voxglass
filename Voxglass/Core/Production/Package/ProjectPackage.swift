import Foundation

public struct ProjectPackage: Sendable, Equatable {
    public let root: URL
    public var integrityFindings: [IntegrityFinding] = []
    public var hasAutosaveRecovery: Bool = false
    public var autosaveSessionURL: URL?
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public var databaseURL: URL { root.appendingPathComponent("project.sqlite") }
    public var autosaveTakesDirectory: URL { root.appendingPathComponent("Autosave/takes") }
    public var autosaveSessionFileURL: URL { root.appendingPathComponent("Autosave/session.json") }

    public static func create(
        title: String,
        author: String,
        narrator: String,
        at directory: URL,
        clock: any Clock,
        ids: any IDGenerator
    ) async throws -> ProjectPackage {
        let fm = FileManager.default

        guard !fm.fileExists(atPath: directory.path) else {
            throw PackageError.notAPackage(directory)
        }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let subdirs = [
                "Audio/Original", "Audio/Render", "Audio/Proxy",
                "Text/source", "Text/extracted",
                "Artwork", "Exports", "Autosave/takes", "Trash", "tmp"
            ]
            for subdir in subdirs {
                try fm.createDirectory(at: directory.appendingPathComponent(subdir, isDirectory: true), withIntermediateDirectories: true)
            }

            let projectID = ids.next()
            let now = clock.now
            let manifest = PackageManifest(
                schemaVersion: 1,
                projectID: projectID,
                title: title,
                author: author,
                narrator: narrator,
                createdAt: now,
                modifiedAt: now,
                appVersion: appVersionString()
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)

            let db = ProjectDatabase(url: directory.appendingPathComponent("project.sqlite"))
            try await db.prepare()

            try setPackageFlag(at: directory)
            fsyncDirectory(at: directory)

            return ProjectPackage(root: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    public static func open(_ url: URL) async throws -> ProjectPackage {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw PackageError.notAPackage(url)
        }

        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw PackageError.notAPackage(url)
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest: PackageManifest
        do {
            manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
        } catch {
            throw PackageError.corruptManifest
        }

        if manifest.packageFormatVersion > PackageManifest.currentPackageFormatVersion {
            throw PackageError.schemaTooNew(manifest.packageFormatVersion)
        }

        // Open the DB and run migrations (spec §6.4).
        let db = ProjectDatabase(url: url.appendingPathComponent("project.sqlite"))
        try await db.prepare()

        // Shallow integrity check: structure + asset presence (spec §6.4).
        var findings: [IntegrityFinding] = []
        let store = SQLiteProductionStore(databaseURL: url.appendingPathComponent("project.sqlite"))
        if let project = try? await store.load() {
            let assets = FileAssetStore(root: url)
            findings = ProjectIntegrity.check(project, assets: assets)
        }

        // Surface autosave recovery if a session exists (spec §6.4).
        let sessionURL = url.appendingPathComponent("Autosave/session.json")
        let hasRecovery = fm.fileExists(atPath: sessionURL.path)

        var pkg = ProjectPackage(root: url)
        pkg.integrityFindings = findings
        pkg.hasAutosaveRecovery = hasRecovery
        pkg.autosaveSessionURL = hasRecovery ? sessionURL : nil
        try setPackageFlag(at: url)
        return pkg
    }

    public static func readManifest(_ url: URL) throws -> PackageManifest {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(PackageManifest.self, from: data)
    }

    public func move(to url: URL) throws {
        try FileManager.default.moveItem(at: root, to: url)
    }

    public func copy(to url: URL) throws {
        let fm = FileManager.default
        let sourceRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let expandedExcludes = (["Audio/Render", "Audio/Proxy", "Exports", "Trash", "tmp"] as Set<String>).map {
            sourceRoot.appendingPathComponent($0).standardizedFileURL.path
        }

        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        let enumerator = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let standardized = item.standardizedFileURL
            let skip = expandedExcludes.contains { standardized.path.hasPrefix($0) }
            if skip { continue }

            var relative: String
            if standardized.path.hasPrefix(sourceRoot.path) {
                relative = String(standardized.path.dropFirst(sourceRoot.path.count + 1))
            } else {
                continue
            }
            if relative.isEmpty { continue }

            let dest = url.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: standardized, to: dest)
            }
        }

        try Self.setPackageFlag(at: url)
    }

    public func setPackageFlag() throws {
        try Self.setPackageFlag(at: root)
    }

    private static func setPackageFlag(at url: URL) throws {
        var values = URLResourceValues()
        values.isPackage = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    private static func fsyncDirectory(at url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }

    private static func appVersionString() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
