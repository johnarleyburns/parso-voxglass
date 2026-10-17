import Foundation
import Testing

@Suite struct FindTabContractTests {
    @Test func findIsTrailingTabAfterNarrate() throws {
        let root = try source("Voxglass/App/RootView.swift")
        let shell = try #require(root.range(of: "private var tabShell"))
        let body = String(root[shell.lowerBound...])
        let order = ["\"Listen\"", "\"My Books\"", "\"Narrate\"", "\"Find\""].compactMap { body.range(of: "Tab(\($0)")?.lowerBound }
        #expect(order.count == 4)
        #expect(order == order.sorted())
        #expect(root.contains("[.listen, .library, .narration, .find]"))
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

    private func source(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
