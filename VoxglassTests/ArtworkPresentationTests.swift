import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ArtworkPresentationTests {
    @Test func exploreAndOnboardingCollectionArtworkFramesAreSquare() throws {
        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let onboarding = try source("Voxglass/Features/Onboarding/OnboardingPreferencesView.swift")

        #expect(discover.contains(".frame(width: 190, height: 190)"))
        #expect(!(discover.contains(".frame(width: 190, height: 132)")))
        #expect(onboarding.contains(".frame(width: 170, height: 170)"))
        #expect(!(onboarding.contains(".frame(width: 170, height: 118)")))
    }

    @Test func bookCoverUsesSharedPostFrameClippingWrapper() throws {
        let artwork = try source("Voxglass/DesignSystem/BookArtworkView.swift")
        let wrapperPattern = #"struct SquareBookCoverView[\s\S]*?BookCoverView\(title:[\s\S]*?\.frame\(width:\s*size,\s*height:\s*size\)[\s\S]*?\.clipShape\([\s\S]*?\.clipped\(\)"#
        #expect(artwork.range(of: wrapperPattern, options: .regularExpression) != nil)  // SquareBookCoverView must apply clipping after the final square frame

        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))
        for file in files where relativePath(file) != "Voxglass/DesignSystem/BookArtworkView.swift" {
            let text = try String(contentsOf: file)
            #expect(!(text.contains("BookCoverView(")))  // \(relativePath(file)) should use BookArtworkView/SquareBookCoverView instead of framing BookCoverView directly
        }
    }

    @Test func sharedBookListRowArtworkFrameIsSquareAndStable() throws {
        let components = try source("Voxglass/DesignSystem/VoxglassComponents.swift")

        #expect(components.contains("BookArtworkView(title: title, size: 56"))
        #expect(components.contains(".frame(width: 56, height: 56)"))
        #expect(components.contains(".fixedSize()"))
    }

    @Test func verticalCatalogResultListsUseGroupedRows() throws {
        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let search = try source("Voxglass/Features/Search/SearchView.swift")
        let discovery = try source("Voxglass/Features/Player/CatalogDiscoveryView.swift")

        for text in [discover, search, discovery] {
            #expect(text.contains("style: .grouped"))
            #expect(text.contains("VoxglassListDivider()"))
            #expect(text.contains(".glassSurface(cornerRadius: 16, fill: Color.white.opacity(0.065))"))
            #expect(text.contains("Button {"))
            #expect(text.contains("Task { await presentResult(result) }"))
        }
    }

    @Test func remoteCatalogResultHandlersPresentPausedNowPlaying() throws {
        let paths = [
            "Voxglass/Features/Discover/DiscoverView.swift",
            "Voxglass/Features/Search/SearchView.swift",
            "Voxglass/Features/Listen/ListenView.swift",
            "Voxglass/Features/Player/CatalogDiscoveryView.swift"
        ]

        for path in paths {
            let text = try source(path)
            #expect(text.contains("private func presentResult"))  // \(path)
            #expect(text.contains("await playback.present(imported)"))  // \(path)
            #expect(text.contains("showingNowPlaying = true"))  // \(path)
            #expect(!text.contains("await playback.play(imported)"))  // \(path)
        }

        let settings = try source("Voxglass/Features/Settings/SettingsView.swift")
        #expect(settings.contains("await playback.present(imported)"))
        #expect(!(settings.contains("await playback.play(imported)")))
    }

    @Test func catalogResultRowsUseNavigationAccessoryWithoutMetadata() throws {
        let search = try source("Voxglass/Features/Search/SearchView.swift")

        #expect(search.contains("accessory: isLoading ? .loading : .navigation"))
        #expect(search.contains("metadata: nil"))
        #expect(!(search.contains("IADateFormatting.humanReadable(result.date)")))
        #expect(!(search.contains("Recorded \\(date)")))
        #expect(!(search.contains("isPlaying ? .loading : .play")))
    }

    @Test func localBookRowsDoNotShowLibraryMetadataDetailLine() throws {
        let components = try source("Voxglass/DesignSystem/VoxglassComponents.swift")

        #expect(components.contains("struct CompactBookRowView: View"))
        #expect(components.contains("metadata: nil"))
        #expect(!(components.contains("metadata: book.libraryDetailLine")))
    }

    @Test func bookDetailHeaderShowsNarratorLineNearTop() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")

        #expect(detail.contains("if let narratorLine = resolved.book.narratorLine"))
        #expect(detail.contains("narratorsLink(resolved, narratorLine: narratorLine)"))
        #expect(detail.contains("chapterLine(resolved)"))
        #expect((try #require(detail.range(of: "narratorsLink(resolved, narratorLine: narratorLine)")?.lowerBound)) < (try #require(detail.range(of: "chapterLine(resolved)")?.lowerBound)))
    }

    @Test func listeningStatsLockIsReservedInsideDisclosureRow() throws {
        let settings = try source("Voxglass/Features/Settings/SettingsView.swift")

        let statsRange = try #require(settings.range(of: "private struct ListeningStatsRow"))
        let nextRange = try #require(settings.range(of: "private struct FolderWatchRow"))
        let statsBlock = String(settings[statsRange.lowerBound..<nextRange.lowerBound])
        #expect(!(statsBlock.contains("ProLockBadge")))
        #expect(!(statsBlock.contains("ProFeature")))
        #expect(!(statsBlock.contains("showsLock")))
    }

    @Test func everyExploreCollectionHasBundledAsset() {
        let assetCatalog = repoRoot.appendingPathComponent("Voxglass/Resources/Assets.xcassets", isDirectory: true)
        // Per-language Great Books variants share the "collection-great-books" artwork.
        let shareGreatBooksArtwork: Set<String> = [
            "great-books-spa", "great-books-deu", "great-books-ita", "great-books-grc"
        ]

        for collection in IACollectionStore.collections(for: []) {
            if shareGreatBooksArtwork.contains(collection.id) {
                #expect(collection.assetName == "collection-great-books")
            } else {
                let expected = "collection-\(collection.id)"
                #expect(collection.assetName == expected)

                let imageset = assetCatalog.appendingPathComponent("\(expected).imageset", isDirectory: true)
                let contents = imageset.appendingPathComponent("Contents.json")
                #expect(FileManager.default.fileExists(atPath: contents.path))  // \(expected) is missing Contents.json

                let imageExists = ["jpg", "jpeg", "png"].contains { ext in
                    FileManager.default.fileExists(atPath: imageset.appendingPathComponent("\(expected).\(ext)").path)
                }
                #expect(imageExists)  // \(expected) is missing an image file
            }
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
