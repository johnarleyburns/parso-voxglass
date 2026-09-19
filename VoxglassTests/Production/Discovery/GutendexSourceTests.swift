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

    @Test func fetchesProjectGutenbergBookThroughGutendex() async throws {
        let json = """
        {
          "count": 1,
          "results": [
            {
              "id": 1342,
              "title": "Pride and Prejudice",
              "authors": [ { "name": "Austen, Jane" } ],
              "bookshelves": ["Romance", "Fiction"],
              "languages": ["en"],
              "copyright": false,
              "formats": {
                "text/html": "https://www.gutenberg.org/ebooks/1342",
                "text/plain; charset=utf-8": "https://www.gutenberg.org/cache/epub/1342/pg1342.txt"
              }
            }
          ]
        }
        """
        let fetcher = StubFetcher(
            url: source.endpoint,
            data: Data(json.utf8),
            finalURL: source.endpoint
        )

        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        let request = fetcher.recordedRequests.first!
        let query = Dictionary(
            uniqueKeysWithValues: URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        )

        #expect(query["copyright"] == "false")
        #expect(query["languages"] == "en")
        #expect(query["sort"] == "popular")
        #expect(needs.count == 1)
        #expect(needs.first?.work.title == "Pride and Prejudice")
        #expect(needs.first?.work.author == "Jane Austen")
        #expect(needs.first?.work.sourcePageURL?.absoluteString == "https://www.gutenberg.org/ebooks/1342")
        #expect(needs.first?.provenance.sources.contains(.gutendex) == true)
    }

    @Test func searchableGutendexRequestCarriesQueryAndPagingConstraints() async throws {
        let client = GutendexSearchClient()
        let json = """
        {
          "count": 2,
          "next": "https://gutendex.com/books?page=2",
          "results": [
            { "id": 1342, "title": "Pride and Prejudice", "authors": [{"name": "Austen, Jane"}], "bookshelves": [], "languages": ["en"], "copyright": false, "formats": {} },
            { "id": 84, "title": "Frankenstein", "authors": [{"name": "Shelley, Mary"}], "bookshelves": [], "languages": ["en"], "copyright": false, "formats": {} }
          ]
        }
        """
        let fetcher = StubFetcher()
        fetcher.setDefault(.init(result: HTTPFetchResult(data: Data(json.utf8), statusCode: 200, finalURL: client.endpoint)))

        let page = try await client.search(query: "Jane Austen", page: 3, using: fetcher)
        let request = try #require(fetcher.recordedRequests.first)
        let query = Dictionary(
            uniqueKeysWithValues: URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        )

        #expect(query["search"] == "Jane Austen")
        #expect(query["page"] == "3")
        #expect(query["languages"] == "en")
        #expect(query["copyright"] == "false")
        #expect(page.results.count == 2)
        #expect(page.results.first?.authorLine == "Jane Austen")
        #expect(page.results.first?.sourcePageURL?.absoluteString == "https://www.gutenberg.org/ebooks/1342")
    }

    @Test func searchableGutendexEmptyResponseIsPreserved() async throws {
        let client = GutendexSearchClient()
        let fetcher = StubFetcher()
        fetcher.setDefault(.init(result: HTTPFetchResult(
            data: Data("{ \"count\": 0, \"results\": [] }".utf8),
            statusCode: 200,
            finalURL: client.endpoint
        )))

        let page = try await client.search(query: "no such book", using: fetcher)
        #expect(page.count == 0)
        #expect(page.results.isEmpty)
        #expect(page.next == nil)
    }

    @Test func searchableGutendexMalformedAndNonOKResponsesAreReported() async throws {
        let client = GutendexSearchClient()
        let malformed = StubFetcher()
        malformed.setDefault(.init(result: HTTPFetchResult(
            data: Data("not json".utf8),
            statusCode: 200,
            finalURL: client.endpoint
        )))
        do {
            _ = try await client.search(query: "book", using: malformed)
            Issue.record("Expected malformed searchable Gutendex JSON to throw")
        } catch is DecodingError {
            // Expected.
        }

        let unavailable = StubFetcher()
        unavailable.setDefault(.init(result: HTTPFetchResult(
            data: Data(),
            statusCode: 503,
            finalURL: client.endpoint
        )))
        do {
            _ = try await client.search(query: "book", using: unavailable)
            Issue.record("Expected searchable Gutendex HTTP status to throw")
        } catch let error as HTTPFetchError {
            #expect(error == .httpStatus(503))
        }
    }

    @Test func searchableGutendexTimeoutAndCancellationRemainDistinct() async throws {
        let client = GutendexSearchClient()
        let timeout = StubFetcher()
        timeout.failAll(.timeout)
        do {
            _ = try await client.search(query: "book", using: timeout)
            Issue.record("Expected searchable Gutendex timeout to throw")
        } catch let error as HTTPFetchError {
            #expect(error == .timeout)
        }

        do {
            _ = try await client.search(query: "book", using: CancellationFetcher())
            Issue.record("Expected searchable Gutendex cancellation to throw")
        } catch is CancellationError {
            // Expected: cancellation must not be presented as a timeout.
        }
    }

    @Test func normalizesProjectGutenbergInputs() {
        #expect(GutenbergInput.ebookID(from: "1342") == "1342")
        #expect(GutenbergInput.ebookID(from: "https://www.gutenberg.org/ebooks/1342/") == "1342")
        #expect(GutenbergInput.ebookID(from: "www.gutenberg.org/cache/epub/1342/pg1342.txt") == "1342")
        // “Project Gutenberg” is a source label, not an ebook identifier. It
        // must produce a useful validation message rather than a malformed URL.
        #expect(GutenbergInput.ebookID(from: "project gutenberg") == nil)
    }

    @Test func nonOKGutendexResponseIsReported() async throws {
        let fetcher = StubFetcher(
            url: source.endpoint,
            data: Data(),
            statusCode: 503,
            finalURL: source.endpoint
        )

        do {
            _ = try await source.fetch(using: fetcher, clock: FixedClock())
            Issue.record("Expected Gutendex HTTP status to throw")
        } catch let error as HTTPFetchError {
            #expect(error == .httpStatus(503))
        }
    }

    @Test func emptyGutendexResponseIsAValidEmptyResult() async throws {
        let json = "{ \"count\": 0, \"results\": [] }"
        let fetcher = StubFetcher(url: source.endpoint, data: Data(json.utf8))
        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        #expect(needs.isEmpty)
    }

    @Test func malformedGutendexResponseIsReported() async throws {
        let fetcher = StubFetcher(url: source.endpoint, data: Data("not json".utf8))

        do {
            _ = try await source.fetch(using: fetcher, clock: FixedClock())
            Issue.record("Expected malformed Gutendex JSON to throw")
        } catch {
            #expect(error is DecodingError)
        }
    }
}

private struct CancellationFetcher: HTTPFetching {
    func get(_ url: URL, timeout: TimeInterval, userAgent: String) async throws -> HTTPFetchResult {
        throw CancellationError()
    }
}
