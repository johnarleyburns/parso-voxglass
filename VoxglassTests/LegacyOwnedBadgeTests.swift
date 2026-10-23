import Testing
import Foundation
@testable import VoxglassCore

@Suite struct LegacyOwnedBadgeTests {
    private func result(_ id: String = "commentaries_blackstone_0810_librivox", callNumber: String?) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: id, title: "Commentaries", creators: [], description: nil,
            collections: [], downloads: nil, date: nil, libriVoxRecordingID: callNumber)
    }

    @MainActor
    private func store(aliases: [String], pending: Bool = false) async throws -> LibraryStore {
        let database = AppDatabase.makeTemporaryDatabase(named: "legacy-badge-\(UUID().uuidString)")
        try await database.prepare()
        let sourceID = UUID(), bookID = UUID()
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'librivox', 'S', 'https://librivox.org/old', 0)",
            [.string(sourceID.uuidString)])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite, is_pending)
        VALUES (?, 'Commentaries', '[]', ?, 0, 0, 0, ?)
        """, [.string(bookID.uuidString), .string(sourceID.uuidString), .int(pending ? 1 : 0)])
        for alias in aliases {
            try await database.execute(
                "INSERT INTO book_recording_identities (book_id, scheme, value, created_at) VALUES (?, 'librivox', ?, 0)",
                [.string(bookID.uuidString), .string(alias)])
        }
        let store = LibraryStore(repository: LibraryRepository(database: database))
        await store.refresh()
        return store
    }

    @Test func searchResponseDecodesNumericAndStringCallNumber() throws {
        let json = """
        {"response":{"numFound":2,"docs":[
        {"identifier":"a","call_number":1735},
        {"identifier":"b","call_number":"01735"},
        {"identifier":"c"}]}}
        """
        let response = try JSONDecoder().decode(InternetArchiveSearchResponse.self, from: Data(json.utf8))
        #expect(response.results[0].libriVoxRecordingID == "1735")
        #expect(response.results[1].libriVoxRecordingID == "01735")
        #expect(response.results[2].libriVoxRecordingID == nil)
    }

    @MainActor
    @Test func aliasBadgesOwnedBookSynchronously() async throws {
        let s = try await store(aliases: ["1735"])
        #expect(s.cachedOwnedBook(for: result(callNumber: "1735")) != nil)
        #expect(s.cachedOwnedBook(for: result(callNumber: "01735")) != nil)
    }

    @MainActor
    @Test func missingMalformedOrMismatchedCallNumberDoesNotBadge() async throws {
        let s = try await store(aliases: ["1735"])
        #expect(s.cachedOwnedBook(for: result(callNumber: nil)) == nil)
        #expect(s.cachedOwnedBook(for: result(callNumber: "17x5")) == nil)
        #expect(s.cachedOwnedBook(for: result(callNumber: "1736")) == nil)
    }

    @MainActor
    @Test func pendingAliasDoesNotBadge() async throws {
        let s = try await store(aliases: ["1735"], pending: true)
        #expect(s.cachedOwnedBook(for: result(callNumber: "1735")) == nil)
    }

    @Test func findAndDiscoverRowsUseResultBasedLookup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Search/SearchView", "Discover/DiscoverView", "Player/CatalogDiscoveryView"] {
            let text = try String(contentsOf: root.appendingPathComponent("Voxglass/Features/\(path).swift"), encoding: .utf8)
            #expect(text.contains("cachedOwnedBook(for: result)"))
            #expect(!text.contains("cachedOwnedBook(forInternetArchiveIdentifier: result.identifier)"))
        }
        let search = try String(contentsOf: root.appendingPathComponent("Voxglass/Features/Search/SearchView.swift"), encoding: .utf8)
        #expect(search.contains("static let ownedLabel = String(localized: \"Already in My Books\")"))
        #expect(search.contains("isInMyBooks ? \"\\(Self.ownedLabel) · \\(result.recordingDetailsLine)\""))
        #expect(search.contains("(isInMyBooks ? [Self.ownedLabel] : [])"))
    }
}
