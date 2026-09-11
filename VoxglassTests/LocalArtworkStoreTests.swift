import Testing
import Foundation
@testable import VoxglassCore

/// `books.cover_url` for app-owned covers (local imports, completed narrations)
/// is persisted relative to Application Support and re-resolved against the
/// current container on read — the same container-move defence
/// `ContainerPathRebase` gives chapter audio.
@Suite struct LocalArtworkStoreTests {

    private func makeContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artstore-\(UUID().uuidString)/Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func remoteURLsPassThroughUnchanged() {
        let remote = "https://archive.org/services/img/some-item?scale=2"
        #expect(LocalArtworkStore.storedValue(for: URL(string: remote)!) == remote)
        #expect(LocalArtworkStore.resolve(remote)?.absoluteString == remote)
    }

    @Test func storesAppOwnedCoverRelativeAndResolvesItBack() throws {
        let container = try makeContainer()
        let coverDir = container.appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let cover = coverDir.appendingPathComponent("cover.jpg")
        try Data("jpeg".utf8).write(to: cover)

        let stored = LocalArtworkStore.storedValue(for: cover, applicationSupport: container)
        #expect(stored == "Voxglass/LocalArtwork/cover.jpg")  // no container path, no scheme

        let resolved = LocalArtworkStore.resolve(stored, applicationSupport: container)
        #expect(resolved?.path == cover.path)
    }

    @Test func resolvesRelativeValueOntoADifferentContainer() throws {
        // Simulates a reinstall: the row was written against one container, the
        // file now lives under a new one, same relative path.
        let newContainer = try makeContainer()
        let coverDir = newContainer.appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let cover = coverDir.appendingPathComponent("abc.jpg")
        try Data("jpeg".utf8).write(to: cover)

        let resolved = LocalArtworkStore.resolve(
            "Voxglass/LocalArtwork/abc.jpg", applicationSupport: newContainer
        )
        #expect(resolved?.path == cover.path)
    }

    @Test func rewritesLegacyAbsoluteFileURLToTheCurrentContainer() throws {
        let container = try makeContainer()
        let coverDir = container.appendingPathComponent("Voxglass/LocalArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let cover = coverDir.appendingPathComponent("legacy.jpg")
        try Data("jpeg".utf8).write(to: cover)

        // The value the buggy build persisted: a stale absolute URL under some
        // *other* container's Application Support.
        let stale = "file:///var/mobile/Containers/Data/Application/OLD-UUID/Library/Application%20Support/Voxglass/LocalArtwork/legacy.jpg"
        let resolved = LocalArtworkStore.resolve(stale, applicationSupport: container)
        #expect(resolved?.path == cover.path)
        // And it now normalises to the relative form.
        #expect(LocalArtworkStore.storedValue(for: resolved!, applicationSupport: container)
            == "Voxglass/LocalArtwork/legacy.jpg")
    }

    @Test func nonAppSupportFileURLIsKeptAbsolute() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: elsewhere)
        let container = try makeContainer()
        #expect(LocalArtworkStore.storedValue(for: elsewhere, applicationSupport: container)
            == elsewhere.absoluteString)
    }
}
