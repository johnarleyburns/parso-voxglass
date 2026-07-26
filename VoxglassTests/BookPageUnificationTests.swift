import Foundation
import Testing
@testable import VoxglassCore

@Suite struct BookPageUnificationTests {
    @Test func legacyDetailAndNowPlayingViewsAreGone() throws {
        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))

        for file in files {
            let text = try String(contentsOf: file)
            let path = relativePath(file)
            #expect(!(text.contains("struct NowPlayingView")))  // \(path) should not contain struct NowPlayingView
            #expect(!(text.contains("struct BookDetailView")))  // \(path) should not contain struct BookDetailView
            #expect(!(text.contains("BookDetailView(book:")))  // \(path) should not contain BookDetailView(book:
        }
    }

    @Test func bookPageKeepsAccessibilityIdentifiers() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")
        let overflow = try source("Voxglass/Features/Player/BookPageOverflowSheet.swift")

        let identifiers = [
            "nowplaying.speed",
            "nowplaying.sleepTimer",
            "nowplaying.bookmark",
            "nowplaying.favorite",
            "nowplaying.download",
            "nowplaying.eq"
        ]

        for id in identifiers {
            let found = page.contains(id) || actionRow.contains(id) || overflow.contains(id)
            #expect(found)  // \(id) must be present in BookPageView, BookPageActionRow, or BookPageOverflowSheet
        }
    }

    @Test func bookPageExposesAirPlay() throws {
        let button = try source("Voxglass/Features/Player/RoutePickerButton.swift")
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        #expect(button.contains("AVRoutePickerView"))  // RoutePickerButton must wrap AVRoutePickerView
        #expect(actionRow.contains("RoutePickerButton"))  // Action row must reference RoutePickerButton
    }

    @Test func actionRowUsesIconsNotFullWidthButtons() throws {
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        #expect(!(actionRow.contains("SecondaryActionButton")))  // Action row must not contain SecondaryActionButton
        #expect(!(actionRow.contains("PrimaryActionButton")))  // Action row must not contain PrimaryActionButton
        #expect(!(actionRow.contains(".frame(height: 46)")))  // Action row must not use 46pt button height
    }

    @Test func descriptionIsClampedWithShowMore() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")

        #expect(page.contains("lineLimit(isDescriptionExpanded ? nil : 1)"))  // Description must be clamped with show more
        #expect(page.contains("Show more"))  // BookPageView must contain Show more
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }

    private func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var result: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(file)
            }
        }
        return result
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }
}
