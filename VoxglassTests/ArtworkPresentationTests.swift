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

    func testBookCoverFramesRemainSquare() throws {
        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))
        let pattern = #"BookCoverView[\s\S]{0,220}?\.frame\(width:\s*([0-9]+),\s*height:\s*([0-9]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var checked = 0

        for file in files {
            let text = try String(contentsOf: file)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let width = try capturedInt(match, at: 1, in: text)
                let height = try capturedInt(match, at: 2, in: text)
                checked += 1
                XCTAssertEqual(width, height, "\(relativePath(file)) has a rectangular BookCoverView frame")
            }
        }

        XCTAssertGreaterThan(checked, 0, "The guard should inspect at least one BookCoverView frame")
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

    private func capturedInt(_ match: NSTextCheckingResult, at index: Int, in text: String) throws -> Int {
        let range = match.range(at: index)
        let swiftRange = try XCTUnwrap(Range(range, in: text))
        return try XCTUnwrap(Int(text[swiftRange]))
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }
}
