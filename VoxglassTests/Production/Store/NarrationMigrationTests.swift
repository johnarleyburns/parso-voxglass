import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

// MARK: - Legacy JSON fixture mirrors (migration source shape, spec §4.3.3)

private struct FixtureTake: Codable {
    var fileName: String
    var duration: TimeInterval
    var peakDBFS: Double?
    var rmsDBFS: Double?
    var clipped: Bool
}

private struct FixtureParagraph: Codable {
    var id: UUID
    var text: String
    var role: String
    var state: String
    var note: String?
    var selectedTake: FixtureTake?
}

private struct FixtureMetadata: Codable {
    var narrator: String
    var language: String
    var description: String
    var subjects: [String]
    var sourceURL: String
    var year: Int?
}

private struct FixtureNarration: Codable {
    var id: UUID
    var title: String
    var author: String
    var sourceText: String
    var sourceURL: String?
    var paragraphs: [FixtureParagraph]
    var createdAt: Date
    var updatedAt: Date
    var metadata: FixtureMetadata?
    var rightsAttested: Bool = false
    var needID: String? = nil
}

// MARK: - Suite

@Suite struct NarrationMigrationTests {

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ fixture: FixtureNarration, to narrationsRoot: URL) throws {
        try FileManager.default.createDirectory(at: narrationsRoot, withIntermediateDirectories: true)
        let data = try NeedsJSONCoding.encoder.encode(fixture)
        try data.write(to: narrationsRoot.appendingPathComponent("\(fixture.id.uuidString).json"))
    }

    private func writeTake(_ data: Data, fileName: String, projectID: UUID, to narrationsRoot: URL) throws {
        let dir = narrationsRoot.appendingPathComponent("\(projectID.uuidString)-takes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(fileName))
    }

    private func writeCorruptJSON(named id: UUID, to narrationsRoot: URL) throws {
        try FileManager.default.createDirectory(at: narrationsRoot, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: narrationsRoot.appendingPathComponent("\(id.uuidString).json"))
    }

    private func loadProject(_ id: UUID, in projectsRoot: URL) async throws -> AudiobookProject {
        let layout = ProductionProjectLayout(root: projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        let store = SQLiteProductionStore(databaseURL: layout.databaseURL)
        return try await store.load()
    }

    /// Three-legacy-narration fixture: one empty (sourceText only), one partly
    /// recorded, one fully approved with a referenced take file plus an orphaned
    /// take file alongside it.
    private func writeStandardFixture(to narrationsRoot: URL) throws {
        let empty = FixtureNarration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Empty Work", author: "Nobody",
            sourceText: "First line of the empty work.\n\nSecond line of the empty work.",
            paragraphs: [],
            createdAt: iso("2025-01-01T00:00:00Z"), updatedAt: iso("2025-01-01T00:00:00Z"),
            needID: "need-empty"
        )

        let p1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let p2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let partialID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let partial = FixtureNarration(
            id: partialID,
            title: "Partial Work", author: "Somebody",
            sourceText: "Partial body text.",
            paragraphs: [
                FixtureParagraph(id: p1, text: "Recorded paragraph.", role: "body", state: "recorded",
                    selectedTake: FixtureTake(fileName: "\(p1.uuidString).caf", duration: 3.0, peakDBFS: -18, rmsDBFS: -24, clipped: false)),
                FixtureParagraph(id: p2, text: "Not recorded yet.", role: "body", state: "notRecorded", selectedTake: nil)
            ],
            createdAt: iso("2025-02-01T00:00:00Z"), updatedAt: iso("2025-02-02T00:00:00Z"),
            needID: "need-partial"
        )
        try write(partial, to: narrationsRoot)
        try writeTake(Data("partial-take-bytes".utf8), fileName: "\(p1.uuidString).caf", projectID: partialID, to: narrationsRoot)

        let approvedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let pa = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let approved = FixtureNarration(
            id: approvedID,
            title: "Approved Work", author: "Anyone",
            sourceText: "Approved body text.",
            sourceURL: "https://example.test/work",
            paragraphs: [
                FixtureParagraph(id: pa, text: "Fully approved paragraph.", role: "body", state: "approved",
                    selectedTake: FixtureTake(fileName: "\(pa.uuidString)-2.caf", duration: 5.0, peakDBFS: -12, rmsDBFS: -20, clipped: false))
            ],
            createdAt: iso("2025-03-01T00:00:00Z"), updatedAt: iso("2025-03-03T00:00:00Z"),
            metadata: FixtureMetadata(narrator: "Reader One", language: "English", description: "d", subjects: ["Poetry"], sourceURL: "https://example.test/work", year: 1923),
            rightsAttested: true,
            needID: "need-approved"
        )
        try write(approved, to: narrationsRoot)
        // Two take files on disk; only the referenced one (-2.caf) may migrate.
        try writeTake(Data("orphaned-take-bytes".utf8), fileName: "\(pa.uuidString).caf", projectID: approvedID, to: narrationsRoot)
        try writeTake(Data("approved-take-bytes".utf8), fileName: "\(pa.uuidString)-2.caf", projectID: approvedID, to: narrationsRoot)

        try write(empty, to: narrationsRoot)
    }

    private func iso(_ string: String) -> Date {
        NeedsJSONCoding.isoDate(string)!
    }

    // MARK: - Tests

    @Test func migratesAllProjectsPreservingParagraphOrderAndText() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()

        #expect(result.migratedProjectCount == 3)
        #expect(result.failedProjectIDs.isEmpty)
        #expect(result.didRun)

        let partialID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]!
        let partial = try await loadProject(partialID, in: projects)
        #expect(partial.metadata.title == "Partial Work")
        #expect(partial.chapters.count == 1)
        #expect(partial.allParagraphs.count == 2)
        #expect(partial.allParagraphs[0].text == "Recorded paragraph.")
        #expect(partial.allParagraphs[1].text == "Not recorded yet.")

        let approvedID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000003")!]!
        let approved = try await loadProject(approvedID, in: projects)
        #expect(approved.metadata.narrator == "Reader One")
        #expect(approved.metadata.copyrightYear == 1923)
        #expect(approved.rights.isAttested)
        #expect(approved.rights.sourceURL?.absoluteString == "https://example.test/work")
        #expect(approved.allParagraphs.count == 1)
        #expect(approved.allParagraphs[0].text == "Fully approved paragraph.")
        #expect(approved.allParagraphs[0].reviewState == .approved)
        #expect(approved.allParagraphs[0].selectedTakeID != nil)
    }

    @Test func emptyNarrationSegmentsItsSourceText() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()
        let emptyID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]!
        let migrated = try await loadProject(emptyID, in: projects)

        #expect(migrated.metadata.title == "Empty Work")
        #expect(migrated.allParagraphs.count == 2)
        #expect(migrated.allParagraphs.map(\.text) == [
            "First line of the empty work.",
            "Second line of the empty work."
        ])
        #expect(migrated.allParagraphs.allSatisfy { $0.takes.isEmpty && $0.selectedTakeID == nil })
    }

    @Test func takeHashesMatchReferencedFilesAndOrphansAreNotCopied() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()

        let partialID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]!
        let partial = try await loadProject(partialID, in: projects)
        let take = partial.allParagraphs[0].takes.first!
        #expect(take.origin == .recorded)
        let partialTakeSHA = try SHA256Hex.hex(Data("partial-take-bytes".utf8))
        #expect(take.assetRef.sha256 == partialTakeSHA)
        // The copied file must exist in the content-addressed store.
        let layout = ProductionProjectLayout(root: projects.appendingPathComponent(partialID.uuidString, isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(take.assetRef.relativePath).path))

        let approvedID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000003")!]!
        let approved = try await loadProject(approvedID, in: projects)
        #expect(approved.allParagraphs[0].takes.count == 1, "orphaned take file must not be copied")
        let approvedTake = approved.allParagraphs[0].takes.first!
        let approvedTakeSHA = try SHA256Hex.hex(Data("approved-take-bytes".utf8))
        #expect(approvedTake.assetRef.sha256 == approvedTakeSHA)
    }

    @Test func reviewStatesMapIntoAudiobookModel() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()

        let partialID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]!
        let partial = try await loadProject(partialID, in: projects)
        #expect(partial.allParagraphs[0].reviewState == .unreviewed)
        #expect(partial.allParagraphs[0].selectedTakeID != nil)
        #expect(partial.allParagraphs[1].reviewState == .unreviewed)
        #expect(partial.allParagraphs[1].selectedTakeID == nil)

        let approvedID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000003")!]!
        let approved = try await loadProject(approvedID, in: projects)
        #expect(approved.allParagraphs[0].reviewState == .approved)
    }

    @Test func deduplicatesByNeedID() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)

        let first = FixtureNarration(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!,
            title: "Duplicate A", author: "Dup",
            sourceText: "Text A.",
            paragraphs: [],
            createdAt: iso("2025-04-01T00:00:00Z"), updatedAt: iso("2025-04-01T00:00:00Z"),
            needID: "need-duplicate"
        )
        let second = FixtureNarration(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!,
            title: "Duplicate B", author: "Dup",
            sourceText: "Text B.",
            paragraphs: [],
            createdAt: iso("2025-04-02T00:00:00Z"), updatedAt: iso("2025-04-03T00:00:00Z"),
            needID: "need-duplicate"
        )
        try write(first, to: narrations)
        try write(second, to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()

        #expect(result.migratedProjectCount == 1)
        // The loser's old id maps to the same new project as the survivor.
        let aID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!]
        let bID = result.mapping[UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!]
        #expect(aID == bID)
        #expect(aID != nil)
        let migrated = try await loadProject(aID!, in: projects)
        #expect(migrated.metadata.title == "Duplicate B", "most complete (newest) narration wins")
    }

    @Test func idempotentAcrossTwoRuns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)

        let migration = NarrationMigration(narrationsRoot: narrations, projectsRoot: projects)
        let first = await migration.runIfNeeded()
        let second = await migration.runIfNeeded()

        #expect(first.didRun)
        #expect(!second.didRun)
        #expect(second.migratedProjectCount == 0)

        // No duplicate projects: the first run's ids are still the only ones.
        let dirs = try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
        #expect(dirs.count == 3)
    }

    @Test func corruptJSONIsSkippedWithoutLosingOthers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let narrations = root.appendingPathComponent("Narrations", isDirectory: true)
        let projects = root.appendingPathComponent("ProductionProjects", isDirectory: true)
        try writeStandardFixture(to: narrations)
        try writeCorruptJSON(named: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, to: narrations)

        let result = await NarrationMigration(narrationsRoot: narrations, projectsRoot: projects).runIfNeeded()

        #expect(result.failedProjectIDs.isEmpty)
        #expect(result.migratedProjectCount == 3)
        #expect(result.skippedCount >= 1)
        #expect(result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000099")!] == nil)
        #expect(result.mapping[UUID(uuidString: "00000000-0000-0000-0000-000000000003")!] != nil)
    }
}
