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

    @Test func remoteCatalogImportsOpenPausedBookPreview() throws {
        let paths = [
            "Voxglass/Features/Discover/DiscoverView.swift",
            "Voxglass/Features/Search/SearchView.swift",
            "Voxglass/Features/Listen/ListenView.swift",
            "Voxglass/Features/Player/CatalogDiscoveryView.swift"
        ]

        for path in paths {
            let text = try source(path)
            #expect(text.contains("private func presentResult"))  // \(path)
            #expect(text.contains("await libraryStore.markBookPending(imported.book.id)"))  // \(path)
            #expect(text.contains("let existingBookIDs = Set(libraryStore.books.map(\\.book.id)"))  // \(path)
            #expect(text.contains("if !existingBookIDs.contains(imported.book.id)"))  // \(path)
            #expect(text.contains("selectedCatalogBookID = imported.book.id"))  // \(path)
            #expect(!(text.contains("await playback.present(imported)")))  // \(path)
            #expect(!text.contains("await playback.play(imported)"))  // \(path)
        }

        let catalog = try source("Voxglass/Features/Player/CatalogDiscoveryView.swift")
        #expect(catalog.contains("let existingBookIDs = Set(libraryStore.books.map(\\.book.id)"))
        #expect(catalog.contains("if !existingBookIDs.contains(imported.book.id)"))

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

    @Test func rootDockReservesItsLiveSafeArea() throws {
        let root = try source("Voxglass/App/RootView.swift")
        let tabs = sourceSlice(root, from: "private var tabs", to: "enum VoxglassTab")
        #expect(tabs.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(tabs.contains("GlassDock("))
        #expect(!tabs.contains("ZStack(alignment: .bottom)"))
    }

    @Test func consumerShellExposesOnlyPlanDestinations() throws {
        let root = try source("Voxglass/App/RootView.swift")
        let tabs = sourceSlice(root, from: "TabView(selection: $selectedTab)", to: "// The dock's safe-area inset")
        #expect(tabs.contains("ListenView("))
        #expect(tabs.contains("LibraryView("))
        #expect(tabs.contains("BrowseView("))
        #expect(tabs.contains("NarrationTabView()"))
        #expect(tabs.components(separatedBy: ".tag(VoxglassTab.").count - 1 == 4)
        #expect(!tabs.contains("SearchView("))

        let dock = try source("Voxglass/Features/Chrome/GlassDock.swift")
        let items = sourceSlice(dock, from: "private let items", to: "var body: some View")
        #expect(items.components(separatedBy: "(.listen,").count - 1 == 1)
        #expect(items.components(separatedBy: "(.library,").count - 1 == 1)
        #expect(items.components(separatedBy: "(.discover,").count - 1 == 1)
        #expect(items.components(separatedBy: "(.narration,").count - 1 == 1)
    }

    @Test func sharedScreenReservesWorstCaseDockHeight() throws {
        let theme = try source("Voxglass/DesignSystem/VoxglassTheme.swift")
        let screen = sourceSlice(theme, from: "struct VoxglassScreen", to: "struct VoxglassBackground")
        #expect(theme.contains("ChromeMetrics.dockItemHeight * 2"))
        #expect(theme.contains("ChromeMetrics.dockStackSpacing"))
        #expect(theme.contains("ChromeMetrics.dockBottomPadding"))
        #expect(theme.contains("static let scrollContentBottomPadding: CGFloat = chromeBottomClearance"))
        #expect(screen.contains(".padding(.bottom, VoxglassLayout.scrollContentBottomPadding)"))
    }

    @Test func editableLibrariesExposeStandardDeleteActions() throws {
        let library = try source("Voxglass/Features/Library/LibraryView.swift")
        let discovery = try source("Voxglass/Features/Production/Discovery/DiscoveryViews.swift")

        #expect(library.contains(".onDelete { offsets in"))
        #expect(library.contains("pendingDeletion = books[index]"))
        #expect(library.contains("allowsFullSwipe: true"))
        #expect(discovery.contains(".onDelete { offsets in"))
        #expect(discovery.contains("pendingDeletion = projects[index]"))
        #expect(discovery.contains("allowsFullSwipe: true"))
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

    @Test func consumerNavigationPlanKeepsTheCommonPathDirect() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        #expect(listen.contains("Continue Listening"))
        #expect(listen.contains("listen.continueListening"))
        #expect(listen.contains("await playback.play(book)"))

        let library = try source("Voxglass/Features/Library/LibraryView.swift")
        #expect(library.contains("metadata: progressText(for: book)"))
        #expect(library.contains("Open Details"))
        #expect(library.contains("@State private var soloOnly = false"))
        #expect(library.contains("Toggle(\"Downloaded\""))
        #expect(library.contains("library.downloadedFilter"))
        #expect(library.contains("library.downloadedEmptyState"))

        let libraryStore = try source("Voxglass/Core/Library/LibraryStore.swift")
        #expect(libraryStore.contains("case .downloaded:"))
        #expect(libraryStore.contains("offlineManager?.state(for: $0.book.id) == .cached"))

        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        #expect(discover.contains("@State private var soloOnly = false"))
        #expect(!(discover.contains("soloOnlyEnabled")))
        #expect(discover.contains("discover.catalogSearch"))
        #expect(discover.contains("discover.filterButton"))

        let search = try source("Voxglass/Features/Search/SearchView.swift")
        #expect(search.contains("@State private var soloOnly = false"))
        #expect(search.contains("search.catalogSearch"))
        #expect(!(search.contains("soloOnlyEnabled")))

        let catalog = try source("Voxglass/Features/Player/CatalogDiscoveryView.swift")
        #expect(catalog.contains("@State private var soloOnly = false"))
        #expect(!(catalog.contains("soloOnlyEnabled")))
        #expect(catalog.contains("catalog.filterMenu"))
        #expect(catalog.contains("Toggle(\"Solo narration\", isOn: $soloOnly)"))
        #expect(!(catalog.contains("FilterChip(title: \"Solo Narration\"")))

        let dock = try source("Voxglass/Features/Chrome/GlassDock.swift")
        #expect(dock.contains("chrome.miniPlayer"))
        #expect(dock.contains("chrome.miniPlayer.playPause"))
        #expect(dock.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(dock.contains("accessibilityLabel(\"Next chapter\")"))

        #expect(library.contains("library.searchButton"))
        #expect(library.contains("library.booksSearch"))

        let discoverSearch = try source("Voxglass/Features/Discover/DiscoverView.swift")
        #expect(discoverSearch.contains("Search catalog for books, authors, or narrators"))
        #expect(library.contains("accessibilityLabel(\"Search My Books\")"))
    }

    @Test func bookPreviewExposesClearLibraryStateAndActions() throws {
        let detail = try source("Voxglass/Features/Player/BookPageView.swift")
        #expect(detail.contains("bookpage.addToLibrary"))
        #expect(detail.contains("bookpage.inMyBooks"))
        #expect(detail.contains("bookpage.previewing"))
        #expect(detail.contains("bookpage.play"))
        #expect(detail.contains("Previewing"))
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
