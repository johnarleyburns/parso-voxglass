import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite struct FolderWatchServiceTests {

    // MARK: - Pure diff helper

    @Test func newAudioFilesFiltersByExtensionAndExcludesKnown() {
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

        #expect(result.contains(mp3))
        #expect(result.contains(flac))
        #expect(!(result.contains(txt)))
        #expect(!(result.contains(jpg)))
        #expect(!(result.contains(known)))  // Known files must be excluded
    }

    // MARK: - Repository idempotency

    @Test func importLocalFolderInsertsSourceBookAndChapters() async throws {
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

        #expect(imported.book.title == "My Folder")
        #expect(imported.chapters.count == 2)
        #expect(imported.chapters.allSatisfy { $0.localURL != nil })
        #expect(imported.chapters.allSatisfy { $0.remoteURL == nil })

        let sources = try await repository.fetchSources()
        #expect(sources.filter { $0.kind == .localFiles }.count == 1)
    }

    @Test func importLocalFolderIsIdempotentAndAppendsNewFiles() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "folder-idempotent")
        let repository = LibraryRepository(database: database)
        let folder = URL(fileURLWithPath: "/tmp/watch-\(UUID().uuidString)")

        let f1 = LocalAudioImport(url: folder.appendingPathComponent("01.mp3"), title: "01", sortKey: "01.mp3", duration: 60)
        let f2 = LocalAudioImport(url: folder.appendingPathComponent("02.mp3"), title: "02", sortKey: "02.mp3", duration: 90)
        let f3 = LocalAudioImport(url: folder.appendingPathComponent("03.mp3"), title: "03", sortKey: "03.mp3", duration: 120)

        _ = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        let rescan = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2])
        #expect(rescan.chapters.count == 2)  // Re-scanning identical files must not duplicate chapters

        let grown = try await repository.importLocalFolder(folderURL: folder, folderName: "F", files: [f1, f2, f3])
        #expect(grown.chapters.count == 3)  // A newly added file must append exactly one chapter

        let library = try await repository.fetchLibrary()
        #expect(library.count == 1)  // One book per folder
        let sources = try await repository.fetchSources()
        #expect(sources.count == 1)  // One source per folder
    }
}
