import XCTest
@testable import VoxglassCore

/// Phase D of docs/MINIPLAYER_RESTORE_PLAN.md — upgrade-proof local file URLs.
/// iOS moves the app data container on update, so absolute `file://` paths
/// persisted before the update go stale. The pure rebase helper re-anchors the
/// suffix after the last well-known sandbox root onto the current container;
/// the repository migration rewrites stale stored rows once per container move.
final class ContainerPathRebaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeNewDocuments(withFile relativePath: String) throws -> (root: URL, file: URL) {
        let root = tempDir.appendingPathComponent("NewContainer/Documents", isDirectory: true)
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: file)
        return (root, file)
    }

    private func staleURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/\(relativePath)")
    }

    // MARK: - Pure helper

    func testRebasesMissingFileOntoMatchingCurrentRoot() throws {
        let (root, file) = try makeNewDocuments(withFile: "Import/ch1.mp3")
        let rebased = ContainerPathRebase.rebase(
            staleURL("Import/ch1.mp3"),
            roots: [.init(marker: "/Documents/", base: root)]
        )
        XCTAssertEqual(rebased.path, file.path)
    }

    func testKeepsURLWhenFileStillExists() throws {
        let (root, file) = try makeNewDocuments(withFile: "Import/ch1.mp3")
        let rebased = ContainerPathRebase.rebase(
            file,
            roots: [.init(marker: "/Documents/", base: root)]
        )
        XCTAssertEqual(rebased, file, "An existing file must never be rewritten")
    }

    func testKeepsURLWhenNoRootMarkerMatches() throws {
        let (root, _) = try makeNewDocuments(withFile: "Import/ch1.mp3")
        let unrelated = URL(fileURLWithPath: "/var/tmp/elsewhere/ch1.mp3")
        let rebased = ContainerPathRebase.rebase(
            unrelated,
            roots: [.init(marker: "/Documents/", base: root)]
        )
        XCTAssertEqual(rebased, unrelated)
    }

    func testKeepsURLWhenRebasedCandidateIsMissingToo() throws {
        let (root, _) = try makeNewDocuments(withFile: "Import/ch1.mp3")
        let stale = staleURL("Import/other-file.mp3")
        let rebased = ContainerPathRebase.rebase(
            stale,
            roots: [.init(marker: "/Documents/", base: root)]
        )
        XCTAssertEqual(rebased, stale, "No blind rewrites: the candidate must exist")
    }

    func testSplitsOnLastMarkerOccurrence() throws {
        let (root, file) = try makeNewDocuments(withFile: "ch1.mp3")
        let nested = URL(fileURLWithPath:
            "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Backup/Documents/ch1.mp3")
        let rebased = ContainerPathRebase.rebase(
            nested,
            roots: [.init(marker: "/Documents/", base: root)]
        )
        XCTAssertEqual(rebased.path, file.path,
                       "The suffix after the *last* root component anchors the rebase")
    }

    func testIgnoresNonFileURLs() {
        let remote = URL(string: "https://archive.org/download/item/ch1.mp3")!
        XCTAssertEqual(ContainerPathRebase.rebase(remote, roots: []), remote)
    }

    // MARK: - Chapter.resolvedPlayableURL integration

    func testResolvedPlayableURLPrefersRemoteWhenLocalMissingAndNoRebase() {
        let chapter = Chapter(
            bookID: UUID(), title: "Ch", index: 0,
            remoteURL: URL(string: "https://archive.org/download/item/ch1.mp3"),
            localURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp3")
        )
        XCTAssertEqual(chapter.resolvedPlayableURL(), chapter.remoteURL)
    }

    func testResolvedPlayableURLReturnsLocalWhenOnlyLocalEvenIfMissing() {
        let local = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp3")
        let chapter = Chapter(bookID: UUID(), title: "Ch", index: 0, localURL: local)
        XCTAssertEqual(chapter.resolvedPlayableURL(), local)
    }

    // MARK: - One-time migration (idempotent, once per container move)

    @MainActor
    func testMigrationRewritesStaleChapterURLOnceAndShortCircuitsAfterMarker() async throws {
        let db = AppDatabase.makeTemporaryDatabase(named: "rebase-\(UUID().uuidString)")
        let repository = LibraryRepository(database: db)
        let defaults = UserDefaults(suiteName: "rebase-\(UUID().uuidString)")!
        let (root, file) = try makeNewDocuments(withFile: "Import/ch1.mp3")

        let bookID = UUID(), chapterID = UUID(), sourceID = UUID()
        let now = Date().timeIntervalSince1970
        try await db.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string("Book"), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        try await db.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Ch"), .string("Ch"),
            .int(0), .double(300), .null, .string(staleURL("Import/ch1.mp3").absoluteString)
        ])

        let roots: [ContainerPathRebase.Root] = [.init(marker: "/Documents/", base: root)]
        let first = await repository.rebaseStaleLocalURLsIfNeeded(
            defaults: defaults, roots: roots, containerMarker: "container-A"
        )
        XCTAssertEqual(first, 1)

        let rows = try await db.query(
            "SELECT local_url FROM chapters WHERE id = ?", [.string(chapterID.uuidString)]
        )
        XCTAssertEqual(rows.first?.string("local_url"), URL(fileURLWithPath: file.path).absoluteString)

        let second = await repository.rebaseStaleLocalURLsIfNeeded(
            defaults: defaults, roots: roots, containerMarker: "container-A"
        )
        XCTAssertEqual(second, 0, "Same container marker — the pass must short-circuit")

        // A later container move (new marker) runs again but finds nothing stale.
        let third = await repository.rebaseStaleLocalURLsIfNeeded(
            defaults: defaults, roots: roots, containerMarker: "container-B"
        )
        XCTAssertEqual(third, 0, "Rewritten rows resolve, so a rerun is a no-op")
    }
}
