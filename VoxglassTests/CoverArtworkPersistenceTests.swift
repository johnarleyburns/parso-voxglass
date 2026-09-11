import Testing
import Foundation
@testable import VoxglassCore

/// Persistence-layer coverage for the local/narration cover-art fix:
/// the schema migration, the one-time launch repair, and the re-import update.
@Suite struct CoverArtworkPersistenceTests {

    @Test func migration13IsRegistered() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "cover-migration-\(UUID().uuidString)")
        let rows = try await db.query("SELECT id FROM schema_migrations ORDER BY id")
        let ids = rows.compactMap { $0.int("id") }.map(Int.init)
        #expect(ids.contains(13))
    }

    @Test func launchRepairRewritesAbsoluteApplicationSupportCoverToRelative() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "cover-repair-\(UUID().uuidString)")
        let repository = LibraryRepository(database: db)
        let defaults = UserDefaults(suiteName: "cover-repair-\(UUID().uuidString)")!

        let appSupport = LocalArtworkStore.applicationSupportDirectory()
        let coverDir = appSupport.appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let cover = coverDir.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: cover)
        defer { try? FileManager.default.removeItem(at: cover) }

        let sourceID = UUID(), bookID = UUID()
        let now = Date().timeIntervalSince1970
        try await db.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        // A stale absolute URL: same relative tail, a different container UUID.
        let stale = "file:///var/mobile/Containers/Data/Application/OLD/Library/Application%20Support/Voxglass/LocalArtwork/\(cover.lastPathComponent)"
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .string(stale), .double(now), .double(now), .bool(false)
        ])

        let changed = await repository.rebaseStaleLocalURLsIfNeeded(
            defaults: defaults, roots: [], containerMarker: "container-A"
        )
        #expect(changed >= 1)

        let row = try await db.query("SELECT cover_url FROM books WHERE id = ?", [.string(bookID.uuidString)]).first
        #expect(row?.string("cover_url") == "Voxglass/LocalArtwork/\(cover.lastPathComponent)")

        // And the read path resolves it back to the on-disk file.
        let book = try await repository.fetchLibrary().first { $0.book.id == bookID }
        #expect(book?.book.coverURL?.path == cover.path)
    }

    @Test func reimportUpdatesCoverURLOnAnExistingBook() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "cover-reimport-\(UUID().uuidString)")
        let repository = LibraryRepository(database: db)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("narration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("ch1.m4a")
        try Data("audio".utf8).write(to: audio)
        let cover = folder.appendingPathComponent("cover.jpg")
        try Data("jpeg".utf8).write(to: cover)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = LocalAudioImport(url: audio, title: "Chapter 1", sortKey: "0001", duration: 60)

        let first = try await repository.importLocalFolder(
            folderURL: folder, folderName: "My Narration", files: [file]
        )
        #expect(first.book.coverURL == nil)

        let second = try await repository.importLocalFolder(
            folderURL: folder, folderName: "My Narration", files: [file], coverURL: cover
        )
        #expect(second.book.id == first.book.id)  // same book, re-imported
        #expect(second.book.coverURL?.path == cover.path)

        // Persisted, not just returned.
        let reloaded = try await repository.fetchLibrary().first { $0.book.id == first.book.id }
        #expect(reloaded?.book.coverURL?.path == cover.path)
    }
}
