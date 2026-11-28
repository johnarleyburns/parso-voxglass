import Foundation
import Testing

@Suite struct FindTabContractTests {
    @Test func findIsTrailingTab() throws {
        let root = try source("Voxglass/App/RootView.swift")
        let shell = try #require(root.range(of: "private var tabShell"))
        let body = String(root[shell.lowerBound...])
        let order = ["\"Listen\"", "\"My Books\"", "\"Find\""].compactMap { body.range(of: "Tab(\($0)")?.lowerBound }
        #expect(order.count == 3)
        #expect(order == order.sorted())
        #expect(root.contains("[.listen, .library, .find]"))
    }

    @Test func legacyAndCurrentAliasesResolveToFind() throws {
        let root = try source("Voxglass/App/RootView.swift")
        #expect(root.contains("case \"find\", \"search\", \"explore\", \"browse\", \"discover\": self = .find"))
    }

    @Test func resultDestinationIsRegisteredInsideScreenContent() throws {
        let text = try source("Voxglass/Features/Discover/DiscoverView.swift")
        let body = try #require(text.range(of: "private var discoverContent"))
        let rest = String(text[body.lowerBound...])
        #expect(rest.contains(".navigationDestination(item: $selectedCatalogResult)"))
        #expect(!text.contains("playback.selectAndPlay"))
        #expect(text.contains("title: \"Find\""))
        #expect(!text.contains("title: \"Discover\""))
    }

    @Test func sourcePickerIsAHeaderMenuLeftOfFilterWithAllFirst() throws {
        let text = try source("Voxglass/Features/Discover/DiscoverView.swift")
        #expect(text.contains("sourceFilter: FindSourceFilter = .all"))
        #expect(!text.contains("BookScopeBar("))
        #expect(text.contains("discover.sourceMenu"))
        #expect(text.contains("Image(systemName: \"books.vertical\")"))
        #expect(text.contains("Text(\"All\").tag(FindSourceFilter.all)"))
        #expect(text.contains("Text(\"LibriVox Collections\").tag(FindSourceFilter.collections)"))

        let header = try #require(text.range(of: "private var discoverHeaderActions"))
        let rest = String(text[header.lowerBound...])
        let sourceMenu = try #require(rest.range(of: "discover.sourceMenu"))
        let filter = try #require(rest.range(of: "discover.filterButton"))
        #expect(sourceMenu.lowerBound < filter.lowerBound)
    }

    @Test func allSourceUsesTheMergedRanker() throws {
        let text = try source("Voxglass/Features/Discover/DiscoverView.swift")
        #expect(text.contains("case .combined:"))
        #expect(text.contains("MergedSearchRanker().rank("))
        #expect(text.contains("await store.searchLibriVox(term)"))
        #expect(text.contains("await searchGutenberg(term, searchID: searchID)"))
    }

    private func source(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
