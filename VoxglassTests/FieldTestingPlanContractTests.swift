import Foundation
import Testing

@Suite struct FieldTestingPlanContractTests {
    @Test func myBooksHeaderOwnsSearchAddAndMoreInOrder() throws {
        let library = try source("Voxglass/Features/Library/LibraryView.swift")
        #expect(library.contains("headerTrailingContent: AnyView(libraryHeaderActions)"))
        #expect(library.contains("accessibilityIdentifier(\"library.searchButton\")"))
        #expect(library.contains("accessibilityIdentifier(\"library.addButton\")"))
        #expect(library.contains("accessibilityIdentifier(\"library.moreMenu\")"))
        #expect(library.range(of: "library.searchButton")!.lowerBound < library.range(of: "library.addButton")!.lowerBound)
        #expect(library.range(of: "library.addButton")!.lowerBound < library.range(of: "library.moreMenu")!.lowerBound)

        let filterBar = sourceSlice(library, from: "private var filterBar", to: "private var libraryHeaderActions")
        #expect(filterBar.contains("progressFilter"))
        #expect(!filterBar.contains("library.searchButton"))
        #expect(!filterBar.contains("library.moreMenu"))
    }

    @Test func discoverUsesCompactCollectionsAndNoDeadCatalogPlaceholder() throws {
        let discover = try source("Voxglass/Features/Discover/DiscoverView.swift")
        #expect(!discover.contains("Browse the catalog"))
        #expect(discover.contains("GeometryReader"))
        #expect(discover.contains(".frame(height: 148)"))
        #expect(discover.contains("accessibilityIdentifier(\"discover.searchButton\")"))
        #expect(discover.contains("accessibilityIdentifier(\"discover.dismissKeyboard\")"))
        #expect(discover.contains("accessibilityIdentifier(\"discover.filterButton\")"))
        #expect(discover.contains("accessibilityIdentifier(\"discover.searchScope\")"))
        #expect(discover.contains("accessibilityIdentifier(\"discover.scopePicker\")"))
        #expect(discover.contains("discover.collectionInfo."))
        #expect(discover.contains("accessibilityIdentifier(\"discover.selectedCollectionAbout\")"))
        #expect(!discover.contains("discover.collectionAbout"))
        #expect(discover.contains(".accessibilityIdentifier(\"discover.selectedCollection\")"))

        let theme = try source("Voxglass/DesignSystem/VoxglassTheme.swift")
        #expect(theme.contains("scrollToTopTrigger"))
        #expect(theme.contains(".scrollDismissesKeyboard(.interactively)"))
    }

    @Test func listenStartsWithActionableContent() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        #expect(!listen.contains("Good listening"))
        #expect(!listen.contains("Public-domain audiobooks, private by default."))
        #expect(listen.contains("Continue Listening"))
        #expect(listen.contains("LazyHStack"))
        #expect(listen.contains("refreshTask?.cancel()"))
        #expect(listen.contains("scheduleHomeRefresh()"))
        #expect(listen.contains("ListenPerformance"))

        let artwork = try source("Voxglass/DesignSystem/ArtworkService.swift")
        #expect(artwork.contains("ArtworkRequestRegistry"))
        #expect(artwork.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(artwork.contains("memoryCache.countLimit"))
        let artworkView = try source("Voxglass/DesignSystem/BookArtworkView.swift")
        #expect(artworkView.contains(".task(id: url)"))
    }

    @Test func chromeUsesColorOnlySelectionAndSharedHeight() throws {
        let dock = try source("Voxglass/Features/Chrome/GlassDock.swift")
        let theme = try source("Voxglass/DesignSystem/VoxglassTheme.swift")
        #expect(!dock.contains("Capsule(style: .continuous)"))
        #expect(dock.contains("struct GlassTabBar"))
        #expect(dock.contains("ChromeMetrics.dockItemHeight"))
        #expect(dock.contains("ChromeMetrics.dockItemHeight"))
        #expect(theme.contains("static let dockItemHeight"))
        #expect(theme.contains("minimumControlHitTarget"))
    }

    @Test func carPlayConstructionUsesValidatedRootsAndGenerationGuards() throws {
        let validation = try source("Voxglass/App/CarPlay/CarPlayTemplateValidation.swift")
        let validationResult = try source("Voxglass/Core/CarPlay/CarPlayTemplateValidationResult.swift")
        let consumer = try source("Voxglass/App/CarPlay/CarPlayInterfaceController.swift")
        let production = try source("Voxglass/App/CarPlay/ProductionCarPlayRenderer.swift")
        let scene = try source("Voxglass/App/CarPlay/CarPlaySceneDelegate.swift")
        #expect(validation.contains("maximumTabCount = 5"))
        #expect(validation.contains("CarPlayTemplateValidationResult"))
        #expect(validationResult.contains("droppedIDs"))
        #expect(validationResult.contains("diagnosticReason"))
        #expect(validationResult.contains("requiresFallback"))
        #expect(validation.contains("droppedIDs"))
        #expect(validation.contains("diagnosticReason"))
        #expect(validation.contains("CarPlayTemplateValidationResult"))
        #expect(!validation.contains("fallbackConsumerTab"))
        #expect(!validation.contains("fallbackProductionTab"))
        #expect(consumer.contains("consumerResult"))
        #expect(production.contains("productionResult"))
        #expect(consumer.contains("fallbackTemplate"))
        #expect(production.contains("fallbackTemplate"))
        let renderer = try source("Voxglass/App/CarPlay/CarPlayTemplateRenderer.swift")
        let productionRenderer = try source("Voxglass/App/CarPlay/ProductionCarPlayRenderer.swift")
        #expect(renderer.contains("-> CPTemplate"))
        #expect(productionRenderer.contains("-> CPTemplate"))
        #expect(renderer.contains("CPListTemplate"))
        #expect(productionRenderer.contains("CPListTemplate"))
        #expect(scene.contains("connectionGeneration"))
        #expect(scene.contains("connectionTask?.cancel()"))
        #expect(scene.contains("guard !Task.isCancelled"))
        #expect(scene.contains("waitForBootstrap"))
        #expect(scene.contains(".seconds(2)"))
    }

    @Test func narrationHomeHidesUnstartedProjectsAndMovesNeedsIntoNewFlow() throws {
        let tab = try source("Voxglass/Features/Production/Discovery/NarrationTabView.swift")
        #expect(tab.contains("contains(where: { $0.recordedCount > 0 })"))
        #expect(sourceSlice(tab, from: "VStack(alignment: .leading", to: "NarrationHomeShelf(")
            .range(of: "MyNarrationsSection()") != nil)

        let views = try source("Voxglass/Features/Production/Discovery/DiscoveryViews.swift")
        #expect(views.contains("narration.startAbout"))
        #expect(!views.contains("Browse community needs"))
        #expect(!views.contains("featuredCard"))
        #expect(!views.contains("Record short works and whole books directly on iPhone."))

        let flow = try source("Voxglass/Features/Production/Discovery/NarrationFlow.swift")
        #expect(flow.contains("Browse narration needs"))
        #expect(flow.contains("NarrationNeedsView(startProject:"))
        #expect(flow.contains("Button(\"Done\") { dismiss() }"))
        #expect(flow.contains("enum NarrationDestinationChoice"))
        #expect(flow.contains("var draftDestinationChoice: NarrationDestinationChoice = .personal"))
        #expect(flow.contains("gutenberg.searchField"))
        #expect(flow.contains("gutenberg.pickBook"))
        #expect(flow.contains("gutenberg.searchLibriVox"))
        #expect(flow.contains("gutenberg.librivoxNoMatch"))
        #expect(flow.contains("private final class GutenbergSearchModel"))
        #expect(flow.contains("fetcher: any HTTPFetching"))
        #expect(flow.contains("archiveClient: any InternetArchiveCatalogClient"))
        #expect(flow.contains("searchGeneration"))
    }

    @Test func planDocumentsTheFieldTestingRequirements() throws {
        let plan = try source("docs/plans/navigation-redesign/FIELD_TEST_FIX_PLAN.md")
        #expect(plan.contains("recordedCount > 0"))
        #expect(plan.contains("Good listening"))
        #expect(plan.contains("Browse narration needs"))
        #expect(plan.contains("Project Gutenberg"))
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
