import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct ProjectPackageTests {

    @Test func createWritesManifestAndSetsPackageFlag() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_create_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = try await ProjectPackage.create(
            title: "Test Book", author: "Author", narrator: "Narrator",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )

        #expect(FileManager.default.fileExists(atPath: pkg.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: pkg.databaseURL.path))

        let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: pkg.manifestURL))
        #expect(manifest.title == "Test Book")
        #expect(manifest.author == "Author")
        #expect(manifest.narrator == "Narrator")
        #expect(manifest.schemaVersion == 1)

        let values = try pkg.root.resourceValues(forKeys: [.isPackageKey])
        #expect(values.isPackage == true)
    }

    @Test func createCreatesDirectoryTree() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_tree_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = try await ProjectPackage.create(
            title: "Tree", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )

        let dirs = ["Audio/Original", "Audio/Render", "Audio/Proxy",
                    "Text/source", "Text/extracted", "Artwork", "Exports",
                    "Autosave/takes", "Trash", "tmp"]
        for d in dirs {
            #expect(FileManager.default.fileExists(atPath: pkg.root.appendingPathComponent(d).path))
        }
    }

    @Test func openReadsManifest() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_open_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try await ProjectPackage.create(
            title: "Open Test", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )

        let opened = try await ProjectPackage.open(tmp)
        #expect(opened.root.path == created.root.path)

        let manifest = try ProjectPackage.readManifest(tmp)
        #expect(manifest.title == "Open Test")
    }

    @Test func openThrowsForNonPackage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_nopkg_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        await #expect(throws: PackageError.self) {
            _ = try await ProjectPackage.open(tmp)
        }
    }

    @Test func openThrowsForMissingManifest() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_nomanifest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        await #expect(throws: PackageError.self) {
            _ = try await ProjectPackage.open(tmp)
        }
    }

    @Test func readManifestIsCheap() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_readmanifest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let manifest = PackageManifest(
            schemaVersion: 1, projectID: UUID(), title: "Quick", author: "A", narrator: "N",
            createdAt: Date(), modifiedAt: Date(), appVersion: "1.0"
        )
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("manifest.json"))

        let read = try ProjectPackage.readManifest(tmp)
        #expect(read.title == "Quick")
    }

    @Test func openThrowsSchemaTooNew() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_schema_new_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = try await ProjectPackage.create(
            title: "Future", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )

        // Rewrite the manifest with a package format version beyond current.
        var manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: pkg.manifestURL))
        manifest.packageFormatVersion = PackageManifest.currentPackageFormatVersion + 1
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: pkg.manifestURL)

        await #expect(throws: PackageError.self) {
            _ = try await ProjectPackage.open(tmp)
        }
    }

    @Test func openSurfacesAutosaveRecovery() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_autosave_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = try await ProjectPackage.create(
            title: "Recover Me", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )
        #expect(!pkg.hasAutosaveRecovery)

        // Simulate a crashed recording session.
        let sessionDir = pkg.root.appendingPathComponent("Autosave")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "{}".write(to: pkg.autosaveSessionFileURL, atomically: true, encoding: .utf8)

        let opened = try await ProjectPackage.open(tmp)
        #expect(opened.hasAutosaveRecovery)
        #expect(opened.autosaveSessionURL == pkg.autosaveSessionFileURL)
    }

    @Test func openRunsIntegrityCheckAndReportsFindings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_integrity_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = try await ProjectPackage.create(
            title: "Broken", author: "A", narrator: "N",
            at: tmp, clock: SystemClock(), ids: UUIDGenerator()
        )
        let store = SQLiteProductionStore(databaseURL: pkg.databaseURL)
        var project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Broken", author: "A", narrator: "N"),
            createdAt: Date(), modifiedAt: Date()
        )
        // A take whose asset file does not exist.
        let missingAsset = AudioAssetReference(
            sha256: "abc", relativePath: "Audio/Original/ab/ab/abc.wav",
            byteCount: 10, contentType: "audio/wav"
        )
        let take = Take(
            id: UUID(),
            paragraphID: UUID(),
            assetRef: missingAsset,
            origin: .recorded,
            recordedAt: Date(), duration: 1.0,
            format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
            processing: [], metrics: nil, label: nil,
            textHashAtRecording: "", isArchived: false
        )
        let para = Paragraph(id: UUID(), ordinal: 0, text: "hello", textHash: "h", takes: [take])
        let chapter = ProductionChapter(id: UUID(), ordinal: 0, title: "C", paragraphs: [para])
        project.chapters = [chapter]
        try await store.save(project)

        // The referenced asset does not exist on disk → blocking finding.
        let opened = try await ProjectPackage.open(tmp)
        #expect(opened.integrityFindings.contains { $0.severity == .blocking })
    }

    @Test func moveChangesRootPath() async throws {
        let srcTmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_move_src_\(UUID().uuidString)")
        let dstTmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_move_dst_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: srcTmp)
            try? FileManager.default.removeItem(at: dstTmp)
        }

        let pkg = try await ProjectPackage.create(title: "Movable", author: "A", narrator: "N", at: srcTmp, clock: SystemClock(), ids: UUIDGenerator())
        try pkg.move(to: dstTmp)

        #expect(FileManager.default.fileExists(atPath: dstTmp.path))
        #expect(!FileManager.default.fileExists(atPath: srcTmp.path))
    }

    @Test func copyExcludesCachesAndExports() async throws {
        let srcTmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_copy_src_\(UUID().uuidString)")
        let dstTmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_copy_dst_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: srcTmp)
            try? FileManager.default.removeItem(at: dstTmp)
        }

        let pkg = try await ProjectPackage.create(title: "Copyable", author: "A", narrator: "N", at: srcTmp, clock: SystemClock(), ids: UUIDGenerator())

        let cacheDir = srcTmp.appendingPathComponent("Audio/Render/x")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try "cached".write(to: cacheDir.appendingPathComponent("test.caf"), atomically: true, encoding: .utf8)

        try pkg.copy(to: dstTmp)
        #expect(FileManager.default.fileExists(atPath: dstTmp.appendingPathComponent("manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: dstTmp.appendingPathComponent("Audio/Render").path))
        #expect(!FileManager.default.fileExists(atPath: dstTmp.appendingPathComponent("Exports").path))
        #expect(!FileManager.default.fileExists(atPath: dstTmp.appendingPathComponent("Trash").path))
    }
}
