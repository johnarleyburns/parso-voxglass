import Foundation
import Testing

/// CarPlay's list rows and the car's Now Playing title are single-line on iOS 27,
/// so all three surfaces must feed them the same compact, parsed chapter line.
@Suite struct CarPlayDisplayTitleContractTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func carPlayChapterRowsUseTheSharedCompactTitle() throws {
        let dispatcher = try read("Voxglass/App/CarPlay/CarPlayActionDispatcher.swift")
        #expect(dispatcher.contains("ChapterDisplayTitles.make(for: book.chapters)"))
        #expect(dispatcher.contains("compactTitle:"))

        let builder = try read("Voxglass/Core/CarPlay/CarPlayMenuBuilder.swift")
        #expect(builder.contains("chapter.compactTitle ?? chapter.title"))
    }

    @Test func nowPlayingTitleUsesTheSharedCompactTitle() throws {
        let coordinator = try read("Voxglass/Core/Playback/PlaybackCoordinator.swift")
        #expect(coordinator.contains("ChapterDisplayTitles.make(for: session.chapters)"))
        #expect(coordinator.contains("chapterDisplay?.compactLine"))
    }
}
