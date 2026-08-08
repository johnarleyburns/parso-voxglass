import Foundation
import VoxglassCore

/// The phone-side repository for narration projects (spec §4.3). Every
/// narration created by the Narration flow is an `AudiobookProject` persisted
/// in its own `.voxproject` package at `Application Support/ProductionProjects/<id>/`
/// through `SQLiteProductionStore` + `ProductionProjectLayout`. This replaces
/// the legacy JSON `NarrationProjectStore`; the legacy tree survives only as a
/// one-way migration source (spec §4.3.3).
///
/// All methods are `@MainActor` because the flows run on the main actor; the
/// underlying SQLite store is serialized by its own actor.
@MainActor
public final class NarrationProjectRepository {
    public let applicationSupport: URL
    public let clock: any Clock
    public let ids: any IDGenerator

    private static let revisionKey = "narration.projectionRevision"

    /// Sync-state key for a project's monotonic projection revision (spec §13.3
    /// staleness check). Shared with `PhoneProductionEnvironment.localPublish`.
    public static let projectionRevisionKey = "narration.projectionRevision"

    /// `nonisolated` so callers in any isolation context can construct a
    /// repository with the default application-support root (the class methods
    /// that touch the store remain main-actor).
    nonisolated public init(
        applicationSupport: URL? = nil,
        clock: any Clock = SystemClock(),
        ids: any IDGenerator = UUIDGenerator()
    ) {
        self.applicationSupport = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.clock = clock
        self.ids = ids
    }

    /// Application Support/ProductionProjects — one package directory per project.
    public var projectsRoot: URL {
        applicationSupport.appendingPathComponent("ProductionProjects", isDirectory: true)
    }

    /// The legacy JSON narration tree; deleted by the migration once receipted.
    public var legacyNarrationsRoot: URL {
        applicationSupport.appendingPathComponent("Voxglass/Narrations", isDirectory: true)
    }

    // MARK: - Migration

    /// Runs the one-way legacy-narration migration if the legacy tree still
    /// exists. Idempotent and self-healing: after the tree is gone it is a
    /// no-op, and a partially failed run retries only the unreceipted files.
    public func runMigrationIfNeeded() async {
        _ = await NarrationMigration(
            narrationsRoot: legacyNarrationsRoot,
            projectsRoot: projectsRoot,
            clock: clock,
            ids: ids
        ).runIfNeeded()
    }

    // MARK: - Project CRUD

    public func layout(for id: UUID) -> ProductionProjectLayout {
        ProductionProjectLayout(applicationSupport: applicationSupport, projectID: id)
    }

    public func store(for id: UUID) -> SQLiteProductionStore {
        SQLiteProductionStore(databaseURL: layout(for: id).databaseURL, clock: clock)
    }

    public func fileStore(for id: UUID) -> FileAssetStore {
        FileAssetStore(root: layout(for: id).root)
    }

    public func allProjects() async -> [AudiobookProject] {
        await runMigrationIfNeeded()
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else { return [] }
        var projects: [AudiobookProject] = []
        for directory in directories where directory.hasDirectoryPath {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            if let project = try? await store(for: id).load() {
                projects.append(project)
            }
        }
        return projects.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func load(_ id: UUID) async throws -> AudiobookProject {
        try await store(for: id).load()
    }

    /// Persists the project, creating the `.voxproject` package directories on
    /// first write. Idempotent for an existing project.
    public func save(_ project: AudiobookProject) async throws {
        await runMigrationIfNeeded()
        let fm = FileManager.default
        let packageRoot = layout(for: project.id).root
        try fm.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        for directory in layout(for: project.id).directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try await store(for: project.id).save(project)
    }

    public func delete(_ id: UUID) async throws {
        try? FileManager.default.removeItem(at: layout(for: id).root)
    }

    // MARK: - Need dedupe (resume-by-need)

    /// Finds an already-started project for the same need (by need ID, then
    /// legacy work identity) so re-tapping a need resumes it instead of
    /// creating a duplicate.
    public func existingProject(for need: NarrationNeed) async -> AudiobookProject? {
        let projects = await allProjects()
        for project in projects {
            if let needID = await needID(for: project.id), needID == need.id {
                return project
            }
        }
        let sourceURL = need.work.sourcePageURL?.absoluteString
        return projects.first { project in
            project.metadata.title == need.work.title
                && project.metadata.author == need.work.author
                && project.rights.sourceURL?.absoluteString == sourceURL
        }
    }

    public func needID(for id: UUID) async -> String? {
        try? await store(for: id).syncValue(NarrationMigration.needIDKey)
    }

    public func setNeedID(_ value: String?, for id: UUID) async throws {
        try await store(for: id).setSyncValue(NarrationMigration.needIDKey, value)
    }

    public func sourceText(for id: UUID) async -> String? {
        try? await store(for: id).syncValue(NarrationMigration.sourceTextKey)
    }

    public func setSourceText(_ value: String, for id: UUID) async throws {
        try await store(for: id).setSyncValue(NarrationMigration.sourceTextKey, value)
    }

    // MARK: - Notes

    /// Latest review-note text per paragraph, in one pass (the flow's paragraph
    /// list shows the flag note on each row).
    public func latestNotes(for id: UUID) async -> [UUID: String] {
        let projectStore = store(for: id)
        guard let summaries = try? await projectStore.paragraphSummaries(chapterID: nil) else { return [:] }
        var notes: [UUID: String] = [:]
        for summary in summaries {
            if let note = summary.latestNoteSnippet {
                notes[summary.id] = note
            }
        }
        return notes
    }

    public func insertNote(_ note: ReviewNote, projectID: UUID) async throws {
        try await store(for: projectID).insertNote(note)
    }

    // MARK: - Takes

    public func autosaveTakesURL(for id: UUID) -> URL {
        layout(for: id).autosaveTakesURL
    }

    /// Moves a freshly captured take file into the content-addressed original
    /// store and builds the `Take` row to attach to its paragraph (spec §9.4
    /// step 4: bytes durable before metadata mutation).
    public func ingestCapturedTake(
        fileURL: URL,
        paragraphID: UUID,
        projectID: UUID,
        captured: CapturedTake,
        textHash: String
    ) async throws -> Take {
        let assets = fileStore(for: projectID)
        let ext = fileURL.pathExtension.isEmpty ? "caf" : fileURL.pathExtension
        let contentType = ext.lowercased() == "wav" ? "audio/wav" : "audio/x-caf"
        let ref = try await assets.ingest(fileAt: fileURL, ext: ext, contentType: contentType, subdirectory: .original, moving: true)
        return Take(
            id: ids.next(),
            paragraphID: paragraphID,
            assetRef: ref,
            origin: .recorded,
            recordedAt: clock.now,
            duration: captured.duration,
            format: captured.format,
            textHashAtRecording: textHash
        )
    }

    /// The on-disk URL of a take's audio in the package's content store.
    public func takeURL(for projectID: UUID, take: Take) -> URL? {
        let url = fileStore(for: projectID).url(for: take.assetRef)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Projection revision (watch staleness)

    /// Returns the next monotonic projection revision for a project, advancing
    /// the persisted counter. The watch uses `revision` to drop stale queues.
    public func nextProjectionRevision(for id: UUID) async -> Int {
        let store = store(for: id)
        let current = (try? await store.syncValue(Self.projectionRevisionKey)).flatMap(Int.init) ?? 0
        let next = current + 1
        try? await store.setSyncValue(Self.projectionRevisionKey, String(next))
        return next
    }

    // MARK: - Reset (UI-test hook)

    /// Removes every project package and the legacy narration tree
    /// (UI-test reset hook; also usable as a user-facing "clear my narrations").
    public func resetAll() {
        try? FileManager.default.removeItem(at: projectsRoot)
        try? FileManager.default.removeItem(at: legacyNarrationsRoot)
    }
}
