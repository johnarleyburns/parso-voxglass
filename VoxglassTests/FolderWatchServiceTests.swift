import XCTest
@testable import Voxglass

@MainActor
final class FolderWatchServiceTests: XCTestCase {

    override func tearDown() {
        EntitlementCache.shared.setTestEntitlement(nil)
        super.tearDown()
    }

    // MARK: - Pure diff helper

    func testNewAudioFilesFiltersByExtensionAndExcludesKnown() {
        let base = URL(fileURLWithPath: "/tmp/folder")
        let mp3 = base.appendingPathComponent("01.mp3")
        let flac = base.appendingPathComponent("02.flac")
        let txt = base.appendingPathComponent("notes.txt")
        let jpg = base.appendingPathComponent("cover.jpg")
        let known = base.appendingPathComponent("03.m4b")

        let result = FolderWatchService.newAudioFiles(
            in: [mp3, flac, txt, jpg, known],
            knownURLs: [known]
        )

        XCTAssertTrue(result.contains(mp3))
        XCTAssertTrue(result.contains(flac))
        XCTAssertFalse(result.contains(txt))
        XCTAssertFalse(result.contains(jpg))
        XCTAssertFalse(result.contains(known), "Known files must be excluded")
    }

    // MARK: - Repository idempotency

    func testImportLocalFolderInsertsSourceBookAndChapters() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-import")
        let repository = LibraryRepository(database: database)
        let folder = URL(fileURLWithPath: "/tmp/watch-\(UUID().uuidString)")

        let imported = try await repository.importLocalFolder(
            folderURL: folder,
            folderName: "My Folder",
            files: [
                LocalAudioImport(url: folder.appendingPathComponent("01.mp3"), title: "01", sortKey: "01.mp3", duration: 60),
                LocalAudioImport(url: folder.appendingPathComponent("02.mp3"), title: "02", sortKey: "02.mp3", duration: 90)
            ]
        )

        XCTAssertEqual(imported.book.title, "My Folder")
        XCTAssertEqual(imported.chapters.count, 2)
        XCTAssertTrue(imported.chapters.allSatisfy { $0.localURL != nil })
        XCTAssertTrue(imported.chapters.allSatisfy { $0.remoteURL == nil })

        let sources = try await repository.fetchSources()
        XCTAssertEqual(sources.filter { $0.kind == .localFiles }.count, 1)
    }

    func testImportLocalFolderIsIdempotentAndAppendsNewFiles() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-idempotent")
        let repository = LibraryRepository(database: database)
        let folder = URL(fileURLWithPath: "/tmp/watch-\(UUID().uuidString)")

        let f1 = LocalAudioImport(url: folder.appendingPathComponent("01.mp3"), title: "01", sortKey: "01.mp3", duration: 60)
        let f2 = LocalAudioImport(url: folder.appendingPathComponent("02.mp3"), title: "02", sortKey: "02.mp3", duration: 90)
        let f3 = LocalAudioImport(url: folder.appendingPathComponent("03.mp3"), title: "03", sortKey: "03.mp3", duration: 120)

        _ = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        let rescan = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        XCTAssertEqual(rescan.chapters.count, 2, "Re-scanning identical files must not duplicate chapters")

        let grown = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2, f3])
        XCTAssertEqual(grown.chapters.count, 3, "A newly added file must append exactly one chapter")

        let library = try await repository.fetchLibrary()
        XCTAssertEqual(library.count, 1, "One book per folder")
        let sources = try await repository.fetchSources()
        XCTAssertEqual(sources.count, 1, "One source per folder")
    }

    // MARK: - Gating

    func testScanSkippedWhenNotEntitled() async throws {
        EntitlementCache.shared.setTestEntitlement(false)
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-gate-off")
        let repository = LibraryRepository(database: database)
        let defaults = UserDefaults(suiteName: "folder-gate-off-\(UUID().uuidString)")!
        let service = FolderWatchService(repository: repository, defaults: defaults)

        let dir = try makeTempAudioFolder(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        await service.addFolder(dir)

        XCTAssertTrue(service.folders.isEmpty, "Not-Pro must not add watched folders")
        let library = try await repository.fetchLibrary()
        XCTAssertTrue(library.isEmpty, "Not-Pro must not import any books")
    }

    func testAddFolderImportsWhenEntitled() async throws {
        EntitlementCache.shared.setTestEntitlement(true)
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-gate-on")
        let repository = LibraryRepository(database: database)
        let defaults = UserDefaults(suiteName: "folder-gate-on-\(UUID().uuidString)")!
        let service = FolderWatchService(repository: repository, defaults: defaults)

        let dir = try makeTempAudioFolder(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        await service.addFolder(dir)

        XCTAssertEqual(service.folders.count, 1, "Pro must add the watched folder")
        let library = try await repository.fetchLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.first?.chapters.count, 2)
    }

    private func makeTempAudioFolder(fileCount: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxglassWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let file = dir.appendingPathComponent(String(format: "%02d.mp3", index + 1))
            try Data("audio".utf8).write(to: file)
        }
        return dir
    }
}
