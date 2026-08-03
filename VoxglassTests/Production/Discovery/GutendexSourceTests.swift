import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct GutendexSourceTests {

    let source = GutendexNeedsSource()

    @Test func decodesPoetryBooksAsSubmittable() throws {
        let json = """
        {
          "count": 2,
          "results": [
            {
              "id": 12242,
              "title": "Hope is the thing with feathers",
              "authors": [ { "name": "Dickinson, Emily", "birth_year": 1830, "death_year": 1886 } ],
              "bookshelves": ["Poetry"],
              "languages": ["en"],
              "copyright": false,
              "formats": {
                "text/html": "https://www.gutenberg.org/ebooks/12242",
                "text/plain": "https://www.gutenberg.org/cache/epub/12242/pg12242.txt",
                "application/epub+zip": "https://www.gutenberg.org/ebooks/12242.epub3.images"
              }
            },
            {
              "id": 9999,
              "title": "Still Under Copyright",
              "authors": [ { "name": "Modern, Author" } ],
              "bookshelves": ["Fiction"],
              "languages": ["en"],
              "copyright": true,
              "formats": { "text/html": "https://www.gutenberg.org/ebooks/9999" }
            }
          ]
        }
        """
        let needs = try source.decode(Data(json.utf8), clock: FixedClock())
        #expect(needs.count == 1)
        let need = needs.first!
        #expect(need.work.title == "Hope is the thing with feathers")
        #expect(need.work.author == "Emily Dickinson")
        #expect(need.isSubmittable)
        #expect(need.provenance.pdBasis == .gutenbergSourced)
        #expect(need.work.sourcePageURL?.host?.hasSuffix("gutenberg.org") == true)
        #expect(need.work.sourceEPUBURL != nil)
        #expect(need.work.lengthClass == .short)
    }

    @Test func decodesProseAsLong() throws {
        let json = """
        {
          "count": 1,
          "results": [
            {
              "id": 84,
              "title": "Frankenstein; Or, The Modern Prometheus",
              "authors": [ { "name": "Shelley, Mary Wollstonecraft" } ],
              "bookshelves": ["Gothic Fiction"],
              "languages": ["en"],
              "copyright": false,
              "formats": { "text/html": "https://www.gutenberg.org/ebooks/84" }
            }
          ]
        }
        """
        let needs = try source.decode(Data(json.utf8), clock: FixedClock())
        let need = needs.first!
        #expect(need.work.lengthClass == .long)
        #expect(need.work.author == "Mary Wollstonecraft Shelley")
    }

    @Test func copyrightMissingIsTreatedAsUnknown() throws {
        // Gutendex omits `copyright` for some records; only `true` is rejected.
        let json = """
        { "count": 1, "results": [ { "id": 1, "title": "Old Text",
          "authors": [ { "name": "Old, Author" } ], "bookshelves": [], "languages": ["en"],
          "formats": { "text/plain": "https://www.gutenberg.org/cache/epub/1/pg1.txt" } } ] }
        """
        let needs = try source.decode(Data(json.utf8), clock: FixedClock())
        #expect(needs.count == 1)
        #expect(needs.first!.work.sourcePageURL?.path.contains("pg1.txt") == true)
    }
}
