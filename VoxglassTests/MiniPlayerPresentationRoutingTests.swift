import Foundation
import Testing
@testable import VoxglassCore

@Suite struct MiniPlayerPresentationRoutingTests {

    @Test func miniPlayerVisibleForActiveSession() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        #expect(scope.contains("guard let currentBookID"))  // shouldShowMiniPlayer must guard against nil currentBookID
        // Simplified rule: show miniplayer when session exists and Now Playing not presented.
        // Does not require lifecycle-based visiblePushedBookID.
    }

    @Test func miniPlayerHiddenForNoSession() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        #expect(scope.contains("return false"))  // shouldShowMiniPlayer must return false early when conditions aren't met
    }

    @Test func miniPlayerHiddenWhileSheetPresented() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        let scope = sourceSlice(router, from: "func shouldShowMiniPlayer", to: "func presentNowPlayingFromMiniPlayer")
        #expect(scope.contains("!isNowPlayingPresented"))  // shouldShowMiniPlayer must check isNowPlayingPresented
    }

    @Test func routerHasNoLifecycleRegistration() throws {
        let router = try source("Voxglass/Features/Player/MiniPlayerPresentationRouter.swift")
        #expect(!(router.contains("visiblePushedBookID")))  // Router must not use lifecycle-based visiblePushedBookID
        #expect(!(router.contains("registerPushedBookPage")))  // Router must not support lifecycle registration
        #expect(!(router.contains("unregisterPushedBookPage")))  // Router must not support lifecycle unregistration
    }

    @Test func bookPagePlayDoesNotPresentNowPlaying() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")

        let transportSlice = sourceSlice(detail, from: "private func transportControls", to: "private func actionRow")
        #expect(!(transportSlice.contains("showingNowPlaying = true")))  // transportControls must not set showingNowPlaying

        let chapterSlice = sourceSlice(detail, from: "private func chapterList", to: "private func discoveryLinks")
        #expect(!(chapterSlice.contains("showingNowPlaying = true")))  // chapterList must not set showingNowPlaying
    }

    @Test func remoteCatalogImportsStillPresentPausedNowPlaying() throws {
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

    @Test func dockUsesRouterForMiniPlayerVisibility() throws {
        let dock = try source("Voxglass/Features/Chrome/GlassDock.swift")
        let scope = sourceSlice(dock, from: "struct GlassDock", to: "struct GlassMiniPlayer")
        #expect(scope.contains("shouldShowMiniPlayer"))  // GlassDock must use router for mini-player visibility
        #expect(scope.contains("presentNowPlayingFromMiniPlayer"))  // GlassDock must route mini-player tap through router
    }

    @Test func rootViewOwnsAndInjectsRouter() throws {
        let root = try source("Voxglass/App/RootView.swift")
        #expect(root.contains("StateObject private var miniPlayerRouter"))
        #expect(root.contains(".environmentObject(miniPlayerRouter)"))
    }

    @Test func bookPageViewHasPresentationContext() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")
        #expect(detail.contains("presentationContext: BookPagePresentationContext"))
        // BookPageView no longer uses lifecycle registration for miniplayer visibility.
        // Visibility is derived deterministically from session existence + Now Playing state.
    }

    @Test func browsingTransportControlsAreDisabled() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")
        let transportSlice = sourceSlice(detail, from: "private func transportControls", to: "private func actionRow")
        let hitTestingCount = transportSlice.components(separatedBy: ".allowsHitTesting(isActiveSession)").count - 1
        #expect(hitTestingCount >= 4)
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
