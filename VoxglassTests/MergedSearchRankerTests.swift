import Testing
import Foundation
@testable import VoxglassCore

@Suite struct MergedSearchRankerTests {
    private let ranker = MergedSearchRanker()

    private func book(
        id: Int,
        title: String,
        author: String,
        subjects: [String] = [],
        languages: [String] = ["en"]
    ) -> GutenbergBook {
        GutenbergBook(
            id: id,
            title: title,
            authors: [.init(name: author)],
            subjects: subjects,
            languages: languages,
            formats: ["application/epub+zip": "https://mirror.test/gutenberg/books/\(id)/pg\(id).epub"]
        )
    }

    private func recording(
        id: String,
        title: String,
        creator: String,
        subjects: [String] = [],
        downloads: Int = 1,
        languages: [String] = ["eng"],
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: id,
            title: title,
            creators: [creator],
            description: nil,
            collections: collections,
            downloads: downloads,
            date: nil,
            languages: languages,
            subjects: subjects
        )
    }

    private func primaryIsReadByAI(_ result: MergedSearchResult) -> Bool {
        if case .readByAI = result.primary { return true }
        return false
    }

    private func primaryIsLibriVox(_ result: MergedSearchResult) -> Bool {
        if case .libriVox = result.primary { return true }
        return false
    }

    @Test func humanNarrationWinsWhenBothSourcesAreTight() {
        let results = ranker.rank(
            query: "frankenstein",
            libriVox: [recording(
                id: "frankenstein_shelley",
                title: "Frankenstein",
                creator: "Mary Shelley",
                downloads: 1_000
            )],
            gutenberg: [book(
                id: 84,
                title: "Frankenstein; or, The Modern Prometheus",
                author: "Shelley, Mary Wollstonecraft"
            )]
        )

        #expect(results.count == 1)
        #expect(primaryIsLibriVox(results[0]))
        #expect(results[0].alternates.count == 1)
        if case .readByAI = results[0].alternates[0] {
            // Expected: the Gutenberg edition is still available.
        } else {
            Issue.record("Expected the Read with AI edition as the alternate")
        }
    }

    @Test func tightGutenbergBeatsALooseLibriVoxSubjectMatch() {
        let results = ranker.rank(
            query: "gothic architecture",
            libriVox: [recording(
                id: "stones_venice",
                title: "The Stones of Venice",
                creator: "John Ruskin",
                subjects: ["Architecture, Gothic"],
                downloads: 5_000
            )],
            gutenberg: [book(
                id: 100,
                title: "Gothic Architecture",
                author: "Ruskin, John",
                subjects: ["Architecture, Gothic"]
            )]
        )

        #expect(results.count == 2)
        #expect(primaryIsReadByAI(results[0]))
        #expect(primaryIsLibriVox(results[1]))
    }

    @Test func gutenbergOnlyWorkStillAppears() {
        let results = ranker.rank(
            query: "tolstoy on art",
            libriVox: [],
            gutenberg: [book(id: 1, title: "Tolstoy on Art", author: "Tolstoy, Leo")]
        )

        #expect(results.count == 1)
        #expect(primaryIsReadByAI(results[0]))
        #expect(results[0].alternates.isEmpty)
    }

    @Test func libriVoxOnlyWorkStillAppears() {
        let results = ranker.rank(
            query: "sherlock holmes",
            libriVox: [recording(
                id: "adventures_holmes",
                title: "The Adventures of Sherlock Holmes",
                creator: "Sir Arthur Conan Doyle"
            )],
            gutenberg: []
        )

        #expect(results.count == 1)
        #expect(primaryIsLibriVox(results[0]))
    }

    @Test func sameTitleDifferentAuthorsStaySeparate() {
        let results = ranker.rank(
            query: "the law",
            libriVox: [recording(
                id: "law_other",
                title: "The Law",
                creator: "Jane Doe"
            )],
            gutenberg: [book(id: 1, title: "The Law", author: "Bastiat, Frédéric")]
        )

        #expect(results.count == 2)
    }

    @Test func volumesAndVersionsCollapseIntoAlternates() {
        let results = ranker.rank(
            query: "war and peace",
            libriVox: [
                recording(
                    id: "war_and_peace_01",
                    title: "War and Peace, Book 01: 1805",
                    creator: "Leo Tolstoy",
                    downloads: 10
                ),
                recording(
                    id: "war_and_peace_02",
                    title: "War and Peace, Book 02: 1805",
                    creator: "Leo Tolstoy",
                    downloads: 100
                )
            ],
            gutenberg: [book(id: 2600, title: "War and Peace", author: "Tolstoy, Leo")]
        )

        #expect(results.count == 1)
        #expect(primaryIsLibriVox(results[0]))
        #expect(results[0].alternates.count == 2)
        if case .libriVox(let primary) = results[0].primary {
            #expect(primary.identifier == "war_and_peace_02")
        } else {
            Issue.record("Expected a human-narrated primary")
        }
    }

    @Test func preferredLanguageBreaksATightGutenbergTie() {
        let results = ranker.rank(
            query: "frankenstein",
            libriVox: [],
            gutenberg: [
                book(id: 2, title: "Frankenstein, ou le Prométhée moderne",
                     author: "Shelley, Mary Wollstonecraft", languages: ["fr"]),
                book(id: 1, title: "Frankenstein; or, The Modern Prometheus",
                     author: "Shelley, Mary Wollstonecraft", languages: ["en"])
            ],
            preferredLanguages: ["eng"]
        )

        #expect(results.count == 1)
        if case .readByAI(let primary) = results[0].primary {
            #expect(primary.id == 1)
        } else {
            Issue.record("Expected the English edition")
        }
    }

    @Test func nonLibriVoxAudioIsIgnored() {
        let results = ranker.rank(
            query: "frankenstein",
            libriVox: [recording(
                id: "tts_frankenstein",
                title: "Frankenstein",
                creator: "Mary Shelley",
                collections: ["audio_bookspoetry"]
            )],
            gutenberg: [book(
                id: 84,
                title: "Frankenstein",
                author: "Shelley, Mary Wollstonecraft"
            )]
        )

        #expect(results.count == 1)
        #expect(primaryIsReadByAI(results[0]))
    }

    @Test func titleAndAuthorKeysStripVolumeAndCreditNoise() {
        #expect(MergedSearchRanker.titleCore("War and Peace, Book 01: 1805") == "war and peace")
        #expect(MergedSearchRanker.titleCore("Frankenstein, ou le Prométhée moderne") == "frankenstein")
        #expect(MergedSearchRanker.titleCore("The Adventures of Sherlock Holmes") == "adventures of sherlock holmes")
        #expect(MergedSearchRanker.titleCore("Kalevala : the Epic Poem of Finland — Complete") == "kalevala")
        #expect(MergedSearchRanker.authorKey("Sir Arthur Conan Doyle") == "doyle")
        #expect(MergedSearchRanker.authorKey("Shelley, Mary Wollstonecraft") == "shelley")
    }
}
