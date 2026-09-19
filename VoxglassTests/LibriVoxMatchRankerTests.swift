import Testing
import VoxglassCore

@Suite struct LibriVoxMatchRankerTests {
    @Test func exactTitleAndAuthorRanksAboveThematicResult() {
        let exact = result(identifier: "exact", title: "Pride and Prejudice", creator: "Jane Austen")
        let thematic = result(
            identifier: "thematic",
            title: "Pride and Prejudice Discussion",
            creator: "A Different Reader",
            description: "A discussion of Pride and Prejudice"
        )

        let ranked = LibriVoxMatchRanker.rank(
            title: "Pride and Prejudice",
            author: "Austen, Jane",
            results: [thematic, exact]
        )

        #expect(ranked.first?.result.identifier == "exact")
        #expect((ranked.first?.score ?? 0) > (ranked.last?.score ?? 0))
    }

    @Test func excludesNonLibriVoxResults() {
        let archiveOnly = result(
            identifier: "archive",
            title: "Pride and Prejudice",
            creator: "Jane Austen",
            collections: ["audio_bookspoetry"]
        )

        #expect(LibriVoxMatchRanker.rank(title: "Pride and Prejudice", author: "Jane Austen", results: [archiveOnly]).isEmpty)
    }

    @Test func normalizesDiacriticsAndPunctuation() {
        #expect(LibriVoxMatchRanker.normalize("Austen, Jáné") == "austen jane")
        #expect(LibriVoxMatchRanker.normalize("  The—Book! ") == "the book")
    }

    @Test func searchQueryIsStrictlyLibriVoxAndEscapesLuceneQuotes() {
        let query = LibriVoxMatchRanker.searchQuery(title: "A \"Great\" Book", author: "Doe, Jane")
        #expect(query.contains("collection:librivoxaudio AND mediatype:audio"))
        #expect(query.contains("title:\"A Great Book\""))
        #expect(query.contains("creator:\"Doe Jane\""))
        #expect(!query.contains("\\\""))
    }

    private func result(
        identifier: String,
        title: String,
        creator: String,
        description: String? = nil,
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: description,
            collections: collections,
            downloads: nil,
            date: nil
        )
    }
}
