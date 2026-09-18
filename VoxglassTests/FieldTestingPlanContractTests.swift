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
        #expect(discover.contains(".frame(height: 132)"))
        #expect(discover.contains("FilterChip(title: selectedCollection.title, isSelected: true, height: 34)"))
        #expect(discover.contains(".accessibilityIdentifier(\"discover.collectionAbout\")"))
        #expect(discover.contains(".accessibilityIdentifier(\"discover.selectedCollection\")"))
    }

    @Test func listenStartsWithActionableContent() throws {
        let listen = try source("Voxglass/Features/Listen/ListenView.swift")
        #expect(!listen.contains("Good listening"))
        #expect(!listen.contains("Public-domain audiobooks, private by default."))
        #expect(listen.contains("Continue Listening"))
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
