import Foundation
import XCTest
@testable import VoxglassCore

final class MiniPlayerPresentationRoutingTests: XCTestCase {

    func testMiniPlayerVisibleForDifferentVisibleBook() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        XCTAssertTrue(scope.contains("guard let currentBookID"), "shouldShowMiniPlayer must guard against nil currentBookID")
        XCTAssertTrue(scope.contains("!isNowPlayingPresented"), "shouldShowMiniPlayer must hide when sheet is presented")
        XCTAssertTrue(scope.contains("visiblePushedBookID != currentBookID"), "shouldShowMiniPlayer must be true when visible book differs from current session")
    }

    func testMiniPlayerHiddenForSameVisibleBook() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        XCTAssertTrue(scope.contains("return false"), "shouldShowMiniPlayer must return false early when conditions aren't met")
    }

    func testMiniPlayerHiddenWhileSheetPresented() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        XCTAssertTrue(scope.contains("!isNowPlayingPresented"), "shouldShowMiniPlayer must check isNowPlayingPresented")
    }

    func testUnregisterDoesNotClearNewerVisibleBook() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func unregisterPushedBookPage", to: "func shouldShowMiniPlayer")
        XCTAssertTrue(scope.contains("if visiblePushedBookID == id"), "unregister must only clear when IDs match")
        XCTAssertTrue(scope.contains("visiblePushedBookID = nil"), "unregister must set visiblePushedBookID to nil on match")
    }

    func testBookPagePlayDoesNotPresentNowPlaying() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")

        let transportSlice = sourceSlice(detail, from: "private func transportControls", to: "private func actionRow")
        XCTAssertFalse(transportSlice.contains("showingNowPlaying = true"),
            "transportControls must not set showingNowPlaying")

        let chapterSlice = sourceSlice(detail, from: "private func chapterList", to: "private func discoveryLinks")
        XCTAssertFalse(chapterSlice.contains("showingNowPlaying = true"),
            "chapterList must not set showingNowPlaying")
    }

    func testRemoteCatalogImportsStillPresentPausedNowPlaying() throws {
        let paths = [
            "Voxglass/Features/Discover/DiscoverView.swift",
            "Voxglass/Features/Search/SearchView.swift",
            "Voxglass/Features/Listen/ListenView.swift",
            "Voxglass/Features/Player/CatalogDiscoveryView.swift"
        ]

        for path in paths {
            let text = try source(path)
            XCTAssertTrue(text.contains("private func presentResult"), path)
            XCTAssertTrue(text.contains("await playback.present(imported)"), "\(path) must use present(imported)")
            XCTAssertTrue(text.contains("showingNowPlaying = true"), "\(path) must still set showingNowPlaying after import")
            XCTAssertFalse(text.contains("await playback.play(imported)"), "\(path) must not call play(imported)")
        }

        let settings = try source("Voxglass/Features/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("await playback.present(imported)"))
        XCTAssertFalse(settings.contains("await playback.play(imported)"))
    }

    func testDockUsesRouterForMiniPlayerVisibility() throws {
        let dock = try source("Voxglass/Features/Chrome/GlassDock.swift")
        let scope = sourceSlice(dock, from: "struct GlassDock", to: "struct GlassMiniPlayer")
        XCTAssertTrue(scope.contains("shouldShowMiniPlayer"), "GlassDock must use router for mini-player visibility")
        XCTAssertTrue(scope.contains("presentNowPlayingFromMiniPlayer"), "GlassDock must route mini-player tap through router")
    }

    func testRootViewOwnsAndInjectsRouter() throws {
        let root = try source("Voxglass/App/RootView.swift")
        XCTAssertTrue(root.contains("StateObject private var miniPlayerRouter"))
        XCTAssertTrue(root.contains(".environmentObject(miniPlayerRouter)"))
    }

    func testBookPageViewHasPresentationContext() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")
        XCTAssertTrue(detail.contains("presentationContext: BookPagePresentationContext"))
        XCTAssertTrue(detail.contains("registerPushedBookPage"))
        XCTAssertTrue(detail.contains("unregisterPushedBookPage"))
    }

    func testBrowsingTransportControlsAreDisabled() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")
        let transportSlice = sourceSlice(detail, from: "private func transportControls", to: "private func actionRow")
        let hitTestingCount = transportSlice.components(separatedBy: ".allowsHitTesting(isActiveSession)").count - 1
        XCTAssertGreaterThanOrEqual(hitTestingCount, 4, "All four side transport buttons must disable hit testing when not active")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }

    private func sourceSlice(_ text: String, from startMarker: String, to endMarker: String) -> String {
        guard let startRange = text.range(of: startMarker) else { return "" }
        let searchRange = startRange.upperBound..<text.endIndex
        guard let endRange = text.range(of: endMarker, range: searchRange) else { return "" }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}
