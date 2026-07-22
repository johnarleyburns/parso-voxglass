import Foundation
import XCTest
@testable import VoxglassCore

final class BookPageUnificationTests: XCTestCase {
    func testLegacyDetailAndNowPlayingViewsAreGone() throws {
        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))

        for file in files {
            let text = try String(contentsOf: file)
            let path = relativePath(file)
            XCTAssertFalse(text.contains("struct NowPlayingView"), "\(path) should not contain struct NowPlayingView")
            XCTAssertFalse(text.contains("struct BookDetailView"), "\(path) should not contain struct BookDetailView")
            XCTAssertFalse(text.contains("BookDetailView(book:"), "\(path) should not contain BookDetailView(book:")
        }
    }

    func testBookPageKeepsAccessibilityIdentifiers() throws {
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
            XCTAssertTrue(found, "\(id) must be present in BookPageView, BookPageActionRow, or BookPageOverflowSheet")
        }
    }

    func testBookPageExposesAirPlay() throws {
        let button = try source("Voxglass/Features/Player/RoutePickerButton.swift")
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        XCTAssertTrue(button.contains("AVRoutePickerView"), "RoutePickerButton must wrap AVRoutePickerView")
        XCTAssertTrue(actionRow.contains("RoutePickerButton"), "Action row must reference RoutePickerButton")
    }

    func testActionRowUsesIconsNotFullWidthButtons() throws {
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        XCTAssertFalse(actionRow.contains("SecondaryActionButton"), "Action row must not contain SecondaryActionButton")
        XCTAssertFalse(actionRow.contains("PrimaryActionButton"), "Action row must not contain PrimaryActionButton")
        XCTAssertFalse(actionRow.contains(".frame(height: 46)"), "Action row must not use 46pt button height")
    }

    func testDescriptionIsClampedWithShowMore() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")

        XCTAssertTrue(page.contains("lineLimit(isDescriptionExpanded ? nil : 1)"), "Description must be clamped with show more")
        XCTAssertTrue(page.contains("Show more"), "BookPageView must contain Show more")
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
