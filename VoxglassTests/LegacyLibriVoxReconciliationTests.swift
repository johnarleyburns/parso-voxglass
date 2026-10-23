import Testing
import Foundation
import os
@testable import VoxglassCore

@Suite struct LegacyLibriVoxReconciliationTests {
    private let slug = "https://librivox.org/commentaries-on-the-laws-of-england-by-blackstone/"
    private let chapterURLs = [
        "https://www.archive.org/download/book_x/book_01.mp3",
        "https://www.archive.org/download/book_x/book_02.mp3"
    ]

    private final class FakeClient: LibriVoxRecordingIdentityClient, Sendable {
        private let counter = OSAllocatedUnfairLock(initialState: 0)
        let recording: LibriVoxRecording
        init(bookURL: String?, listenURLs: [String]) {
            recording = LibriVoxRecording(
                bookURL: bookURL.flatMap(URL.init(string:)),
                sections: listenURLs.map {
                    LibriVoxSection(sectionNumber: nil, listenURL: $0, fileName: nil, readers: [], urlIArchive: nil)
                })
        }
        var calls: Int { counter.withLock { $0 } }
        func fetchRecording(bookID: Int) async throws -> LibriVoxRecording {
            counter.withLock { $0 += 1 }
            return recording
        }
    }

    private struct Seeded { let bookID: UUID; let chapterIDs: [UUID] }

    private func seed(
        _ database: AppDatabase, sourceURL: String?, chapters: [String], title: String = "Commentaries"
    ) async throws -> Seeded {
        let sourceID = UUID(), bookID = UUID()
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'librivox', 'S', ?, 0)",
            [.string(sourceID.uuidString), sourceURL.map { .string($0) } ?? .null])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite, is_pending)
        VALUES (?, ?, '[]', ?, 0, 0, 0, 0)
        """, [.string(bookID.uuidString), .string(title), .string(sourceID.uuidString)])
        var ids: [UUID] = []
        for (i, url) in chapters.enumerated() {
            let id = UUID(); ids.append(id)
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url)
            VALUES (?, ?, ?, ?, ?, 60, ?)
            """, [.string(id.uuidString), .string(bookID.uuidString), .string("C\(i)"),
                  .string("C\(i)"), .int(Int64(i)), .string(url)])
        }
        if ids.count > 1 {
            try await database.execute("""
            INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
            VALUES (?, ?, ?, 42.5, 60, 7, 0)
            """, [.string(UUID().uuidString), .string(bookID.uuidString), .string(ids[1].uuidString)])
            try await database.execute("""
            INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at)
            VALUES (?, ?, ?, 12, 'n', 3)
            """, [.string(UUID().uuidString), .string(bookID.uuidString), .string(ids[1].uuidString)])
        }
        return Seeded(bookID: bookID, chapterIDs: ids)
    }

    private func snapshot(_ database: AppDatabase) async throws -> [String] {
        var out: [String] = []
        for sql in [
            "SELECT id || '|' || is_pending || '|' || title AS d FROM books ORDER BY id",
            "SELECT id || '|' || book_id || '|' || remote_url AS d FROM chapters ORDER BY id",
            "SELECT id || '|' || book_id || '|' || chapter_id || '|' || position_seconds || '|' || updated_at AS d FROM playback_positions ORDER BY id",
            "SELECT id || '|' || book_id || '|' || chapter_id || '|' || position_seconds || '|' || note AS d FROM bookmarks ORDER BY id"
        ] {
            out += try await database.query(sql).compactMap { $0.string("d") }
        }
        return out
    }

    private func aliases(_ database: AppDatabase) async throws -> [String] {
        try await database.query("SELECT book_id, scheme, value FROM book_recording_identities ORDER BY value")
            .map { "\($0.string("book_id") ?? "")/\($0.string("scheme") ?? "")/\($0.string("value") ?? "")" }
    }

    private func make() async throws -> (AppDatabase, LibraryRepository) {
        let database = AppDatabase.makeTemporaryDatabase(named: "legacy-reconcile-\(UUID().uuidString)")
        try await database.prepare()
        return (database, LibraryRepository(database: database))
    }

    @Test func exactSourceURLLinksAndPreservesListenerData() async throws {
        let (database, repo) = try await make()
        let seeded = try await seed(database, sourceURL: "HTTPS://LibriVox.org/commentaries-on-the-laws-of-england-by-blackstone", chapters: chapterURLs)
        #expect(try await aliases(database).isEmpty)
        let before = try await snapshot(database)
        let client = FakeClient(bookURL: slug, listenURLs: [])
        let result = try await repo.reconcileLegacyLibriVoxRecording("01735", using: client)
        guard case .linked(let linked) = result else { Issue.record("expected linked, got \(result)"); return }
        #expect(linked.book.id == seeded.bookID)
        #expect(try await aliases(database) == ["\(seeded.bookID.uuidString)/librivox/1735"])
        #expect(try await snapshot(database) == before)
        #expect(try await database.query("SELECT 1 FROM playback_positions WHERE chapter_id = ? AND position_seconds = 42.5",
                                         [.string(seeded.chapterIDs[1].uuidString)]).count == 1)
    }

    @Test func exactListenURLSequenceLinksWithoutSourceURL() async throws {
        let (database, repo) = try await make()
        let seeded = try await seed(database, sourceURL: nil, chapters: chapterURLs)
        let before = try await snapshot(database)
        let client = FakeClient(bookURL: nil, listenURLs: chapterURLs.map { $0.replacingOccurrences(of: "www.archive.org", with: "WWW.Archive.org") })
        let result = try await repo.reconcileLegacyLibriVoxRecording("1735", using: client)
        guard case .linked(let linked) = result else { Issue.record("expected linked, got \(result)"); return }
        #expect(linked.book.id == seeded.bookID)
        #expect(try await aliases(database) == ["\(seeded.bookID.uuidString)/librivox/1735"])
        #expect(try await snapshot(database) == before)
    }

    @Test func nonExactEvidenceWritesNothing() async throws {
        let cases: [(String, String, FakeClient)] = [
            ("same title and filename stems", "1735", FakeClient(
                bookURL: "https://librivox.org/other-book/",
                listenURLs: ["https://other.org/a/book_01.mp3", "https://other.org/a/book_02.mp3"])),
            ("partial sequence", "1735", FakeClient(bookURL: nil, listenURLs: [chapterURLs[0]])),
            ("query mismatch", "1735", FakeClient(bookURL: nil, listenURLs: [chapterURLs[0] + "?x=1", chapterURLs[1]])),
            ("slug contained only", "1735", FakeClient(bookURL: slug + "extra", listenURLs: [])),
            ("malformed id", "17x5", FakeClient(bookURL: slug, listenURLs: chapterURLs))
        ]
        for (name, id, client) in cases {
            let (database, repo) = try await make()
            _ = try await seed(database, sourceURL: slug + "part", chapters: chapterURLs)
            let before = try await snapshot(database)
            let result = try await repo.reconcileLegacyLibriVoxRecording(id, using: client)
            #expect(result == .noExactEvidence, "\(name)")
            #expect(try await aliases(database).isEmpty, "\(name)")
            #expect(try await snapshot(database) == before, "\(name)")
        }
    }

    @Test func twoExactCandidatesAreAmbiguous() async throws {
        let (database, repo) = try await make()
        let a = try await seed(database, sourceURL: slug, chapters: chapterURLs)
        let b = try await seed(database, sourceURL: slug, chapters: chapterURLs)
        let before = try await snapshot(database)
        let result = try await repo.reconcileLegacyLibriVoxRecording(
            "1735", using: FakeClient(bookURL: slug, listenURLs: []))
        guard case .ambiguous(let ids) = result else { Issue.record("expected ambiguous, got \(result)"); return }
        #expect(Set(ids) == [a.bookID, b.bookID])
        #expect(try await aliases(database).isEmpty)
        #expect(try await snapshot(database) == before)
    }

    @Test func existingAliasReturnsWithoutNetwork() async throws {
        let (database, repo) = try await make()
        let seeded = try await seed(database, sourceURL: nil, chapters: chapterURLs)
        try await database.execute(
            "INSERT INTO book_recording_identities (book_id, scheme, value, created_at) VALUES (?, 'librivox', '1735', 0)",
            [.string(seeded.bookID.uuidString)])
        let client = FakeClient(bookURL: slug, listenURLs: chapterURLs)
        let result = try await repo.reconcileLegacyLibriVoxRecording("1735", using: client)
        guard case .linked(let linked) = result else { Issue.record("expected linked"); return }
        #expect(linked.book.id == seeded.bookID)
        #expect(client.calls == 0)
    }

    @Test func aliasConflictIsSurfaced() async throws {
        let (database, _) = try await make()
        let owner = try await seed(database, sourceURL: nil, chapters: [])
        let other = try await seed(database, sourceURL: nil, chapters: [])
        try await database.execute(
            "INSERT INTO book_recording_identities (book_id, scheme, value, created_at) VALUES (?, 'librivox', '1735', 0)",
            [.string(owner.bookID.uuidString)])
        await #expect(throws: LibraryRepository.RecordingIdentityError.self) {
            _ = try await database.claimRecordingIdentity(
                bookID: other.bookID.uuidString, scheme: "librivox", value: "1735")
                .nonConflicting(with: other.bookID.uuidString)
        }
        #expect(try await aliases(database) == ["\(owner.bookID.uuidString)/librivox/1735"])
        // Same owner is idempotent.
        let again = try await database.claimRecordingIdentity(
            bookID: owner.bookID.uuidString, scheme: "librivox", value: "1735")
        #expect(again == owner.bookID.uuidString)
    }

    /// Fake whose fetch suspends until the test releases it.
    private final class GatedClient: LibriVoxRecordingIdentityClient, Sendable {
        private struct State { var started = false; var continuation: CheckedContinuation<Void, Never>? }
        private let state = OSAllocatedUnfairLock(initialState: State())
        let recording: LibriVoxRecording
        init(bookURL: String) {
            recording = LibriVoxRecording(bookURL: URL(string: bookURL), sections: [])
        }
        func fetchRecording(bookID: Int) async throws -> LibriVoxRecording {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                state.withLock { $0.started = true; $0.continuation = c }
            }
            return recording
        }
        func waitUntilStarted() async {
            while !state.withLock({ $0.started && $0.continuation != nil }) { await Task.yield() }
        }
        func complete() {
            state.withLock { $0.continuation.take() }?.resume()
        }
    }

    @Test func cancelledPreflightCannotClaimAliasAfterRecordingFetchReturns() async throws {
        let (database, repo) = try await make()
        _ = try await seed(database, sourceURL: slug, chapters: chapterURLs)
        let before = try await snapshot(database)
        let fake = GatedClient(bookURL: slug)
        let task = Task { try await repo.reconcileLegacyLibriVoxRecording("1735", using: fake) }
        await fake.waitUntilStarted()
        task.cancel()
        fake.complete()
        let result = try await task.value
        #expect(result == .noExactEvidence)
        #expect(try await aliases(database).isEmpty)
        #expect(try await snapshot(database) == before)
    }

    @Test func nonCancelledGatedProofWritesExactlyOneAlias() async throws {
        let (database, repo) = try await make()
        let seeded = try await seed(database, sourceURL: slug, chapters: chapterURLs)
        let fake = GatedClient(bookURL: slug)
        let task = Task { try await repo.reconcileLegacyLibriVoxRecording("1735", using: fake) }
        await fake.waitUntilStarted()
        fake.complete()
        _ = try await task.value
        #expect(try await aliases(database) == ["\(seeded.bookID.uuidString)/librivox/1735"])
    }

    @Test func findViewsCancelPreflightOnDraftEditAndClear() throws {
        let root = repositoryRoot()
        let search = try String(contentsOf: root.appendingPathComponent("Voxglass/Features/Search/SearchView.swift"), encoding: .utf8)
        let discover = try String(contentsOf: root.appendingPathComponent("Voxglass/Features/Discover/DiscoverView.swift"), encoding: .utf8)
        let cancel = "preflightTask?.cancel()\n"
        for (name, text) in [("search", search), ("discover", discover)] {
            let onChange = text.range(of: ".onChange(of: catalogStore.query)")
            #expect(onChange != nil, "\(name) onChange")
            if let r = onChange { #expect(text[r.upperBound...].prefix(160).contains("preflightTask?.cancel()"), "\(name)") }
            _ = cancel
        }
        #expect(search.range(of: "preflightTask?.cancel()\n                    preflightTask = nil\n                    catalogStore.query = \"\"") != nil)
        #expect(discover.range(of: "preflightTask?.cancel()\n        preflightTask = nil\n        searchLifecycle.reset()\n        catalogStore.query = \"\"") != nil)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}

private extension String {
    func nonConflicting(with id: String) throws -> String {
        if self != id { throw LibraryRepository.RecordingIdentityError.ambiguous(scheme: "librivox", value: "1735") }
        return self
    }
}
