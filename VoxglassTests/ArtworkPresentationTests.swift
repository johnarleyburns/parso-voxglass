import Foundation
import XCTest
@testable import VoxglassCore

final class ArtworkPresentationTests: XCTestCase {
    func testExploreAndOnboardingCollectionArtworkFramesAreSquare() throws {
        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let onboarding = try source("Voxglass/Features/Onboarding/OnboardingPreferencesView.swift")

        XCTAssertTrue(discover.contains(".frame(width: 190, height: 190)"))
        XCTAssertFalse(discover.contains(".frame(width: 190, height: 132)"))
        XCTAssertTrue(onboarding.contains(".frame(width: 170, height: 170)"))
        XCTAssertFalse(onboarding.contains(".frame(width: 170, height: 118)"))
    }

    func testBookCoverUsesSharedPostFrameClippingWrapper() throws {
        let artwork = try source("Voxglass/DesignSystem/BookArtworkView.swift")
        let wrapperPattern = #"struct SquareBookCoverView[\s\S]*?BookCoverView\(title:[\s\S]*?\.frame\(width:\s*size,\s*height:\s*size\)[\s\S]*?\.clipShape\([\s\S]*?\.clipped\(\)"#
        XCTAssertNotNil(
            artwork.range(of: wrapperPattern, options: .regularExpression),
            "SquareBookCoverView must apply clipping after the final square frame"
        )

        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))
        for file in files where relativePath(file) != "Voxglass/DesignSystem/BookArtworkView.swift" {
            let text = try String(contentsOf: file)
            XCTAssertFalse(
                text.contains("BookCoverView("),
                "\(relativePath(file)) should use BookArtworkView/SquareBookCoverView instead of framing BookCoverView directly"
            )
        }
    }

    func testSharedBookListRowArtworkFrameIsSquareAndStable() throws {
        let components = try source("Voxglass/DesignSystem/VoxglassComponents.swift")

        XCTAssertTrue(components.contains("BookArtworkView(title: title, size: 56"))
        XCTAssertTrue(components.contains(".frame(width: 56, height: 56)"))
        XCTAssertTrue(components.contains(".fixedSize()"))
    }

    func testVerticalCatalogResultListsUseGroupedRows() throws {
        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let search = try source("Voxglass/Features/Search/SearchView.swift")
        let discovery = try source("Voxglass/Features/Player/CatalogDiscoveryView.swift")

        for text in [discover, search, discovery] {
            XCTAssertTrue(text.contains("style: .grouped"))
            XCTAssertTrue(text.contains("VoxglassListDivider()"))
            XCTAssertTrue(text.contains(".glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))"))
            XCTAssertTrue(text.contains("NavigationLink {"))
            XCTAssertTrue(text.contains("CatalogBookDetailView("))
        }
    }

    func testCatalogResultRowsUseNavigationAccessoryWithoutMetadata() throws {
        let search = try source("Voxglass/Features/Search/SearchView.swift")

        XCTAssertTrue(search.contains("accessory: .navigation"))
        XCTAssertTrue(search.contains("metadata: nil"))
        XCTAssertFalse(search.contains("IADateFormatting.humanReadable(result.date)"))
        XCTAssertFalse(search.contains("Recorded \\(date)"))
        XCTAssertFalse(search.contains("isPlaying ? .loading : .play"))
    }

    func testLocalBookRowsDoNotShowLibraryMetadataDetailLine() throws {
        let components = try source("Voxglass/DesignSystem/VoxglassComponents.swift")

        XCTAssertTrue(components.contains("struct CompactBookRowView: View"))
        XCTAssertTrue(components.contains("metadata: nil"))
        XCTAssertFalse(components.contains("metadata: book.libraryDetailLine"))
    }

    func testBookDetailHeaderShowsNarratorLineNearTop() throws {
        let detail = try source("Voxglass/Features/Library/BookDetailView.swift")

        XCTAssertTrue(detail.contains("if let narratorLine = currentBook.book.narratorLine"))
        XCTAssertTrue(detail.contains("Text(narratorLine)"))
        XCTAssertLessThan(
            try XCTUnwrap(detail.range(of: "Text(narratorLine)")?.lowerBound),
            try XCTUnwrap(detail.range(of: "Text(currentBook.libraryDetailLine")?.lowerBound)
        )
    }

    func testListeningStatsLockIsReservedInsideDisclosureRow() throws {
        let settings = try source("Voxglass/Features/Settings/SettingsView.swift")

        XCTAssertTrue(settings.contains("showsLock: !ProFeature.isEnabled(.listeningStats)"))
        let statsRange = try XCTUnwrap(settings.range(of: "private struct ListeningStatsRow"))
        let nextRange = try XCTUnwrap(settings.range(of: "private struct FolderWatchRow"))
        let statsBlock = String(settings[statsRange.lowerBound..<nextRange.lowerBound])
        XCTAssertFalse(statsBlock.contains(".overlay(alignment: .trailing)"))
    }

    func testEveryExploreCollectionHasBundledAsset() {
        let assetCatalog = repoRoot.appendingPathComponent("Voxglass/Resources/Assets.xcassets", isDirectory: true)

        for collection in IACollectionStore.collections(for: []) {
            let expected = "collection-\(collection.id)"
            XCTAssertEqual(collection.assetName, expected, collection.id)

            let imageset = assetCatalog.appendingPathComponent("\(expected).imageset", isDirectory: true)
            let contents = imageset.appendingPathComponent("Contents.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: contents.path), "\(expected) is missing Contents.json")

            let imageExists = ["jpg", "jpeg", "png"].contains { ext in
                FileManager.default.fileExists(atPath: imageset.appendingPathComponent("\(expected).\(ext)").path)
            }
            XCTAssertTrue(imageExists, "\(expected) is missing an image file")
        }
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
