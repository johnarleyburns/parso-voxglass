import Testing
import Foundation
import os
@testable import VoxglassCore

private final class CountingHasher: LocalMediaFileHasher {
    private let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
    var readCount: Int { reads.withLock { $0.count } }
    func sha256Hex(of url: URL) throws -> String {
        reads.withLock { $0.append(url.lastPathComponent) }
        return try SHA256Hex.hex(contentsOf: url)
    }
}

private struct FileResolver: LocalMediaFileResolver {
    func resolve(localURL: URL?, bookmark: Data?) -> URL? {
        guard let localURL, FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }
}

@Suite(.serialized) struct LocalMediaFingerprintTests {
    private struct Chapter { var file: URL; var index: Int; var start: Double; var duration: Double }

    private let root: URL
    private let database: AppDatabase
    private let hasher = CountingHasher()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lmf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = AppDatabase.makeTemporaryDatabase(named: "lmf-\(UUID().uuidString)")
    }

    private func service() -> LocalMediaFingerprintService {
        LocalMediaFingerprintService(database: database, hasher: hasher, resolver: FileResolver())
    }

    private func write(_ name: String, in folder: String, bytes: String) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func insertBook(kind: SourceKind = .localFiles, chapters: [Chapter], bookmark: Data? = nil) async throws -> String {
        try await database.prepare()
        let sourceID = UUID().uuidString, bookID = UUID().uuidString
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, 'S', NULL, 0)",
            [.string(sourceID), .string(kind.rawValue)])
        try await database.execute(
            "INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at) VALUES (?, 'T', '[]', ?, 0, 0)",
            [.string(bookID), .string(sourceID)])
        for c in chapters {
            try await database.execute(
                """
                INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, start_time_seconds, duration_seconds, local_url, local_bookmark)
                VALUES (?, ?, 'c', ?, ?, ?, ?, ?, ?)
                """,
                [.string(UUID().uuidString), .string(bookID), .string(String(format: "%04d", c.index)),
                 .int(Int64(c.index)), .double(c.start), .double(c.duration),
                 .string(c.file.absoluteString), ModelMapping.databaseValue(bookmark)])
        }
        return bookID
    }

    private func digest(_ result: LocalMediaFingerprintResult) throws -> LocalMediaFingerprint {
        guard case .fingerprinted(let fp, _) = result else { throw CancellationError() }
        return fp
    }

    @Test func sameBytesAndBoundariesProduceStableV1Digest() async throws {
        let a = try write("a.mp3", in: "x", bytes: "AAA")
        let b = try write("a.mp3", in: "y", bytes: "AAA")
        let one = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        let two = try await insertBook(chapters: [Chapter(file: b, index: 0, start: 0, duration: 10)])
        let s = service()
        let f1 = try digest(try await s.fingerprint(bookID: one))
        let f2 = try digest(try await s.fingerprint(bookID: two))
        #expect(f1 == f2)
        #expect(f1.scheme == "local-media-v1")
        #expect(f1.bookDigest.count == 64)
        #expect(LocalMediaIdentity.contentKey(f1) == "local-media:v1:\(f1.bookDigest)")
    }

    @Test func movedFolderProducesSameDigest() async throws {
        let a = try write("t.mp3", in: "before", bytes: "BYTES")
        let id = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 5)])
        let first = try digest(try await service().fingerprint(bookID: id))
        let moved = try write("renamed.mp3", in: "after/deep", bytes: "BYTES")
        let id2 = try await insertBook(chapters: [Chapter(file: moved, index: 0, start: 0, duration: 5)])
        #expect(try digest(try await service().fingerprint(bookID: id2)) == first)
    }

    @Test func changedAudioBytesProduceDifferentDigest() async throws {
        let a = try write("a.mp3", in: "x", bytes: "AAA")
        let b = try write("a.mp3", in: "y", bytes: "AAB")
        let one = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        let two = try await insertBook(chapters: [Chapter(file: b, index: 0, start: 0, duration: 10)])
        let s = service()
        #expect(try digest(try await s.fingerprint(bookID: one)).bookDigest
                != (try digest(try await s.fingerprint(bookID: two))).bookDigest)
    }

    @Test func changedSharedFileChapterBoundariesProduceDifferentDigest() async throws {
        let m = try write("b.m4b", in: "x", bytes: "BOOK")
        let one = try await insertBook(chapters: [
            Chapter(file: m, index: 0, start: 0, duration: 60), Chapter(file: m, index: 1, start: 60, duration: 60)])
        let two = try await insertBook(chapters: [
            Chapter(file: m, index: 0, start: 0, duration: 70), Chapter(file: m, index: 1, start: 70, duration: 50)])
        let s = service()
        #expect(try digest(try await s.fingerprint(bookID: one)).bookDigest
                != (try digest(try await s.fingerprint(bookID: two))).bookDigest)
    }

    @Test func sharedM4BIsReadAndHashedOnce() async throws {
        let m = try write("b.m4b", in: "x", bytes: "BOOK")
        let id = try await insertBook(chapters: (0..<5).map {
            Chapter(file: m, index: $0, start: Double($0) * 10, duration: 10) })
        let fp = try digest(try await service().fingerprint(bookID: id))
        #expect(hasher.readCount == 1)
        #expect(fp.chapterDigests.count == 5)
    }

    @Test func manifestContainsNoPathOrBookmarkBytes() async throws {
        let a = try write("secret-name.mp3", in: "private-folder", bytes: "AAA")
        let id = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)],
                                      bookmark: Data("BOOKMARK-BYTES".utf8))
        _ = try await service().fingerprint(bookID: id)
        let rows = try await database.query("SELECT * FROM local_media_fingerprints WHERE book_id = ?", [.string(id)])
        let blob = rows[0].values.values.compactMap(\.stringValue).joined()
        for needle in ["secret-name", "private-folder", "BOOKMARK", root.lastPathComponent, "file://"] {
            #expect(!blob.contains(needle))
        }
    }

    @Test func persistedDigestIsReusedWithoutReadingFileAgain() async throws {
        let a = try write("a.mp3", in: "x", bytes: "AAA")
        let id = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        let first = try digest(try await service().fingerprint(bookID: id))
        #expect(hasher.readCount == 1)
        let again = try await service().fingerprint(bookID: id)
        #expect(again == .fingerprinted(first, fromCache: true))
        #expect(hasher.readCount == 1)
    }

    @Test func inaccessibleBookReturnsPendingWithoutMutatingLibrary() async throws {
        let a = try write("a.mp3", in: "x", bytes: "AAA")
        let id = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        try FileManager.default.removeItem(at: a)
        let before = try await database.query("SELECT * FROM chapters ORDER BY id")
        let result = try await service().fingerprint(bookID: id)
        guard case .pending = result else { Issue.record("expected pending"); return }
        let after = try await database.query("SELECT * FROM chapters ORDER BY id")
        #expect(before.map(\.values) == after.map(\.values))
        #expect(try await database.query("SELECT * FROM local_media_fingerprints").isEmpty)
        #expect(hasher.readCount == 0)
    }

    @Test func unrelatedRemoteBooksAreNeverFingerprintCandidates() async throws {
        let a = try write("a.mp3", in: "x", bytes: "AAA")
        let local = try await insertBook(chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        try await insertBook(kind: .librivox, chapters: [Chapter(file: a, index: 0, start: 0, duration: 10)])
        let s = service()
        #expect(try await s.candidateBookIDs() == [local])
        let all = try await s.fingerprintAllCandidates()
        #expect(Set(all.keys) == [local])
    }
}
