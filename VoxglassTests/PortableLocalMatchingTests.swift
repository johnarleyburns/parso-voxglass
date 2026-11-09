import Testing
import Foundation
import CloudKit
@testable import VoxglassCore

private struct PlainResolver: LocalMediaFileResolver {
    func resolve(localURL: URL?, bookmark: Data?) -> URL? {
        guard let localURL, FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }
}

@Suite(.serialized) struct PortableLocalMatchingTests {
    private let root: URL
    private let phoneA: AppDatabase
    private let phoneB: AppDatabase

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        phoneA = AppDatabase.makeTemporaryDatabase(named: "plm-a-\(UUID().uuidString)")
        phoneB = AppDatabase.makeTemporaryDatabase(named: "plm-b-\(UUID().uuidString)")
    }

    private func write(_ name: String, folder: String, bytes: String) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    /// Shared-M4B fixture: two logical chapters in one file.
    @discardableResult
    private func insertLocalBook(_ db: AppDatabase, file: URL, title: String = "Local Title") async throws -> (book: String, chapters: [String]) {
        try await db.prepare()
        let sourceID = UUID().uuidString, bookID = UUID().uuidString
        try await db.execute("INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'localFiles', 'S', NULL, 0)", [.string(sourceID)])
        try await db.execute("INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at) VALUES (?, ?, '[]', ?, 0, 0)",
                             [.string(bookID), .string(title), .string(sourceID)])
        var ids: [String] = []
        for (i, start) in [0.0, 60.0].enumerated() {
            let id = UUID().uuidString
            ids.append(id)
            try await db.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, local_url)
            VALUES (?, ?, 'c', ?, ?, ?, 60, ?)
            """, [.string(id), .string(bookID), .string("000\(i)"), .int(Int64(i)), .double(start), .string(file.absoluteString)])
        }
        return (bookID, ids)
    }

    private func fingerprint(_ db: AppDatabase, book: String) async throws -> String {
        let service = LocalMediaFingerprintService(database: db, resolver: PlainResolver())
        guard case .fingerprinted(let fp, _) = try await service.fingerprint(bookID: book) else { throw CancellationError() }
        return LocalMediaIdentity.contentKey(fp)
    }

    private struct Upload {
        var key: String
        var placeholder: CloudKitRecordMapper.PortableLocalPlaceholder
        var chapterIDs: [UUID]
    }

    /// Phone A: fingerprints its copy and builds the record phone B would receive.
    private func upload(file: URL, favorite: Bool = true) async throws -> Upload {
        let a = try await insertLocalBook(phoneA, file: file, title: "Remote Title")
        let key = try await fingerprint(phoneA, book: a.book)
        let book = Book(id: UUID(uuidString: a.book)!, title: "Remote Title", authors: ["Auth"], sourceID: UUID(), isFavorite: favorite)
        let chapters = a.chapters.enumerated().map { i, id in
            Chapter(id: UUID(uuidString: id)!, bookID: book.id, title: "c", index: i, startTime: Double(i) * 60, duration: 60,
                    localURL: file, localBookmark: Data([9]))
        }
        let record = try #require(CloudKitRecordMapper.portableLocalBookRecord(from: book, chapters: chapters, contentKey: key))
        let placeholder = try #require(CloudKitRecordMapper.portableLocalPlaceholder(from: record))
        return Upload(key: key, placeholder: placeholder, chapterIDs: chapters.map(\.id))
    }

    private func count(_ db: AppDatabase, _ sql: String) async throws -> Int64 {
        try await db.query(sql).first?.int("n") ?? -1
    }

    @Test func exactManifestMatchAttachesRemoteMetadataToExistingLocalBook() async throws {
        let fileA = try write("b.m4b", folder: "a", bytes: "SHARED")
        let up = try await upload(file: fileA)
        let fileB = try write("renamed.m4b", folder: "b/deep", bytes: "SHARED")
        let local = try await insertLocalBook(phoneB, file: fileB, title: "Filename")
        _ = try await fingerprint(phoneB, book: local.book)
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        let resolved = try await svc.resolvePending()
        #expect(resolved == [UUID(uuidString: local.book)!])
        let row = try await phoneB.query("SELECT title, is_favorite, content_key FROM books WHERE id=?", [.string(local.book)]).first
        #expect(row?.string("title") == "Remote Title")
        #expect(row?.int("is_favorite") == 1)
        #expect(row?.string("content_key") == up.key)
        #expect(try await svc.unresolvedContentKeys().isEmpty)
    }

    @Test func noMatchCreatesNoPlayableBook() async throws {
        let up = try await upload(file: try write("b.m4b", folder: "a", bytes: "ONLY-A"))
        try await phoneB.prepare()
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        #expect(try await svc.resolvePending().isEmpty)
        #expect(try await count(phoneB, "SELECT COUNT(*) AS n FROM books") == 0)
        #expect(try await count(phoneB, "SELECT COUNT(*) AS n FROM chapters") == 0)
        #expect(try await svc.unresolvedContentKeys() == [up.key])
        #expect(try await svc.diagnostics().isEmpty)
    }

    @Test func rescanLaterResolvesPreviouslyUnmatchedMetadata() async throws {
        let up = try await upload(file: try write("b.m4b", folder: "a", bytes: "LATER"))
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        #expect(try await svc.resolvePending().isEmpty)
        let fileB = try write("b.m4b", folder: "restored", bytes: "LATER")
        let local = try await insertLocalBook(phoneB, file: fileB)
        _ = try await fingerprint(phoneB, book: local.book)
        #expect(try await svc.resolvePending() == [UUID(uuidString: local.book)!])
        #expect(try await svc.unresolvedContentKeys().isEmpty)
    }

    @Test func ambiguousDigestNeverChoosesFirstBook() async throws {
        let up = try await upload(file: try write("b.m4b", folder: "a", bytes: "DUP"))
        var ids: [String] = []
        for folder in ["one", "two"] {
            let l = try await insertLocalBook(phoneB, file: try write("b.m4b", folder: folder, bytes: "DUP"), title: "Mine-\(folder)")
            _ = try await fingerprint(phoneB, book: l.book)
            ids.append(l.book)
        }
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        #expect(try await svc.resolvePending().isEmpty)
        #expect(try await count(phoneB, "SELECT COUNT(*) AS n FROM books WHERE title='Remote Title' OR content_key IS NOT NULL") == 0)
        let diag = try #require(try await svc.diagnostics().first)
        #expect(Set(diag.candidateBookIDs.map(\.uuidString)) == Set(ids))
        #expect(PortableLocalMatcher.match(remoteContentKey: up.key, localCandidates: []) == .none)
    }

    private func resolveWithState(position: PlaybackPosition?, bookmark: Bookmark?, localSeed: (String, [String]) async throws -> Void = { _, _ in }) async throws -> (String, [String], PortableLocalMetadataService) {
        let up = try await upload(file: try write("b.m4b", folder: "a", bytes: "STATE"))
        let local = try await insertLocalBook(phoneB, file: try write("b.m4b", folder: "b", bytes: "STATE"))
        _ = try await fingerprint(phoneB, book: local.book)
        try await localSeed(local.book, local.chapters)
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        if var p = position {
            p.chapterID = up.chapterIDs[1]
            #expect(try await svc.retainPosition(p, bookRecordName: CloudKitRecordMapper.bookRecordName(contentKey: up.key)))
        }
        if var b = bookmark {
            b.chapterID = up.chapterIDs[1]
            #expect(try await svc.retainBookmark(b, bookRecordName: CloudKitRecordMapper.bookRecordName(contentKey: up.key)))
        }
        _ = try await svc.resolvePending()
        return (local.book, local.chapters, svc)
    }

    @Test func matchingPreservesNewerLocalPlaybackPosition() async throws {
        let older = PlaybackPosition(bookID: UUID(), chapterID: UUID(), position: 5, duration: 60, updatedAt: Date(timeIntervalSince1970: 100))
        let (book, chapters, _) = try await resolveWithState(position: older, bookmark: nil) { book, chapters in
            try await phoneB.execute("""
            INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
            VALUES (?, ?, ?, 40, 60, 500, 0)
            """, [.string(UUID().uuidString), .string(book), .string(chapters[1])])
        }
        let row = try await phoneB.query("SELECT position_seconds, updated_at FROM playback_positions WHERE book_id=? AND chapter_id=?",
                                         [.string(book), .string(chapters[1])]).first
        #expect(row?.double("position_seconds") == 40)
        #expect(row?.double("updated_at") == 500)
    }

    @Test func matchingImportsNewerRemoteBookmark() async throws {
        let remote = Bookmark(id: UUID(), bookID: UUID(), chapterID: UUID(), position: 12, note: "n", createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 900))
        let position = PlaybackPosition(bookID: UUID(), chapterID: UUID(), position: 7, duration: 60, updatedAt: Date(timeIntervalSince1970: 800))
        let (book, chapters, _) = try await resolveWithState(position: position, bookmark: remote)
        let bm = try await phoneB.query("SELECT chapter_id, position_seconds, note FROM bookmarks WHERE book_id=?", [.string(book)]).first
        #expect(bm?.string("chapter_id") == chapters[1])
        #expect(bm?.double("position_seconds") == 12)
        let pos = try await phoneB.query("SELECT position_seconds FROM playback_positions WHERE book_id=? AND chapter_id=?",
                                         [.string(book), .string(chapters[1])]).first
        #expect(pos?.double("position_seconds") == 7)
    }

    @Test func matchingDoesNotAlterAudioURLsOrSecurityBookmarks() async throws {
        let fileB = try write("b.m4b", folder: "b", bytes: "URLS")
        let up = try await upload(file: try write("b.m4b", folder: "a", bytes: "URLS"))
        let local = try await insertLocalBook(phoneB, file: fileB)
        try await phoneB.execute("UPDATE chapters SET local_bookmark = ? WHERE book_id = ?", [ModelMapping.databaseValue(Data([7, 7])), .string(local.book)])
        _ = try await fingerprint(phoneB, book: local.book)
        let before = try await phoneB.query("SELECT id, local_url, local_bookmark FROM chapters WHERE book_id=? ORDER BY chapter_index", [.string(local.book)])
        let svc = PortableLocalMetadataService(database: phoneB)
        try await svc.retainBook(up.placeholder)
        _ = try await svc.resolvePending()
        let after = try await phoneB.query("SELECT id, local_url, local_bookmark FROM chapters WHERE book_id=? ORDER BY chapter_index", [.string(local.book)])
        #expect(before.map { $0.string("local_url") } == after.map { $0.string("local_url") })
        #expect(after.allSatisfy { ModelMapping.data($0, "local_bookmark") == Data([7, 7]) })
        #expect(before.map { $0.string("id") } == after.map { $0.string("id") })
        let json = try await phoneB.query("SELECT COUNT(*) AS n FROM unresolved_portable_local").first?.int("n")
        #expect(json == 0)
    }

    @Test func remoteBookAndReadWithAIMatchingAreUnchanged() {
        let id = UUID()
        let candidate = CachedLocalManifest(localBookID: id, fingerprint: LocalMediaFingerprint(bookDigest: "abc", chapterDigests: []))
        #expect(PortableLocalMatcher.match(remoteContentKey: "librivox:123", localCandidates: [candidate]) == .none)
        #expect(PortableLocalMatcher.match(remoteContentKey: "readwithai:abc", localCandidates: [candidate]) == .none)
        #expect(PortableLocalMatcher.match(remoteContentKey: "local-media:v1:abc", localCandidates: [candidate]) == .exact(localBookID: id))
        #expect(PortableLocalMatcher.match(remoteContentKey: "local-media:v1:abd", localCandidates: [candidate]) == .none)
    }
}
