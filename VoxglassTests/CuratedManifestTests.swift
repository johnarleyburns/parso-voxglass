import Foundation
import Testing
@testable import VoxglassCore

struct CuratedManifestTests {
    // MARK: - Manifest validity

    @Test func greatBooksManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "great-books")
        #expect(!manifest.isEmpty, "Great Books manifest should be non-empty")
    }

    @Test func greaterBooksManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "greater-books")
        #expect(!manifest.isEmpty, "Greater Books manifest should be non-empty")
    }

    @Test func greatBooksRanksStrictlyIncreasing() {
        let manifest = CuratedManifest.load(named: "great-books")
        let ranks = manifest.map(\.rank)
        #expect(ranks == ranks.sorted(), "Ranks should be in ascending order")
    }

    @Test func greaterBooksRanksStrictlyIncreasing() {
        let manifest = CuratedManifest.load(named: "greater-books")
        let ranks = manifest.map(\.rank)
        #expect(ranks == ranks.sorted(), "Ranks should be in ascending order")
    }

    @Test func greatBooksIdentifiersAreUnique() {
        let manifest = CuratedManifest.load(named: "great-books")
        let ids = manifest.map(\.identifier)
        #expect(Set(ids).count == ids.count, "All identifiers should be unique")
    }

    @Test func greaterBooksIdentifiersAreUnique() {
        let manifest = CuratedManifest.load(named: "greater-books")
        let ids = manifest.map(\.identifier)
        #expect(Set(ids).count == ids.count, "All identifiers should be unique")
    }

    @Test func greatBooksRank1IsHomer() {
        let manifest = CuratedManifest.load(named: "great-books")
        let first = manifest.first
        #expect(first?.rank == 1)
        #expect(first?.author.localizedCaseInsensitiveContains("Homer") == true)
    }

    @Test func greaterBooksRank1IsHomer() {
        let manifest = CuratedManifest.load(named: "greater-books")
        let first = manifest.first
        #expect(first?.rank == 1)
        #expect(first?.author.localizedCaseInsensitiveContains("Homer") == true)
        #expect(first?.title.localizedCaseInsensitiveContains("Odyssey") == true)
    }

    @Test func greaterBooksManifestUsesGeneratedBulkAudit() {
        let manifest = CuratedManifest.load(named: "greater-books")
        #expect(manifest.count == 916)
        #expect(CollectionBundledCounts.counts["greater-books"] == manifest.count)
        #expect(manifest.contains { $0.identifier == "herodotus_histories_2_0906_librivox2" })
        #expect(manifest.contains { $0.identifier == "platos_republic_0902_librivox1" })
        #expect(!manifest.contains { $0.identifier == "historiaherodoto4_1508_librivox" })
        #expect(!manifest.contains { $0.identifier == "alcibiades1_1212_librivox" })
    }

    @Test func curatedBundledCountsMatchManifestCounts() {
        for collection in IACollectionStore.curated {
            guard let name = collection.curatedListName else {
                Issue.record("Curated collection \(collection.id) is missing curatedListName")
                continue
            }
            let manifest = CuratedManifest.load(named: name)
            #expect(CollectionBundledCounts.counts[collection.id] == manifest.count)
        }
    }

    @Test func greaterBooksSourceAndReportAreConsistent() throws {
        struct Work: Decodable {
            let rank: Int
            let period: String
            let author: String
            let title: String
        }
        struct ZeroCoverageWork: Decodable {}
        struct Report: Decodable {
            let totalWorks: Int
            let manifestCount: Int
            let coveredWorks: Int
            let zeroCoverageWorks: [ZeroCoverageWork]
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let worksURL = root.appendingPathComponent("Tools/CuratedLists/greater-books-works.json")
        let reportURL = root.appendingPathComponent("Tools/CuratedLists/out/greater-books-report.json")
        let works = try JSONDecoder().decode([Work].self, from: Data(contentsOf: worksURL))
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))

        #expect(works.count == 540)
        #expect(works.filter { $0.period == "Prehistory to 700 A. D." }.count == 94)
        #expect(works.filter { $0.period == "700 to 1650" }.count == 85)
        #expect(works.filter { $0.period == "1650 to 1900" }.count == 239)
        #expect(works.filter { $0.period == "1900 to present" }.count == 122)
        #expect(works.filter { $0.author.isEmpty }.count == 12)
        #expect(works.first?.rank == 1)
        #expect(works.first?.author == "Homer")
        #expect(works.first?.title == "The Odyssey")

        let manifest = CuratedManifest.load(named: "greater-books")
        #expect(report.totalWorks == works.count)
        #expect(report.manifestCount == manifest.count)
        #expect(report.coveredWorks == 340)
        #expect(report.zeroCoverageWorks.count == report.totalWorks - report.coveredWorks)
    }

    // MARK: - Per-language manifest validation

    @Test func spanishManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "great-books-spa")
        #expect(!manifest.isEmpty, "Spanish Great Books manifest should be non-empty")
    }

    @Test func germanManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "great-books-deu")
        #expect(!manifest.isEmpty, "German Great Books manifest should be non-empty")
    }

    @Test func italianManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "great-books-ita")
        #expect(!manifest.isEmpty, "Italian Great Books manifest should be non-empty")
    }

    @Test func greekManifestIsNonEmpty() {
        let manifest = CuratedManifest.load(named: "great-books-grc")
        #expect(!manifest.isEmpty, "Greek Great Books manifest should be non-empty")
    }

    @Test func perLanguageManifestsHaveUniqueIdentifiers() {
        for name in ["great-books-spa", "great-books-deu", "great-books-ita", "great-books-grc"] {
            let manifest = CuratedManifest.load(named: name)
            let ids = manifest.map(\.identifier)
            #expect(Set(ids).count == ids.count, "\(name): identifiers should be unique")
        }
    }

    @Test func perLanguageManifestRanksAreIncreasing() {
        for name in ["great-books-spa", "great-books-deu", "great-books-ita", "great-books-grc"] {
            let manifest = CuratedManifest.load(named: name)
            let ranks = manifest.map(\.rank)
            #expect(ranks == ranks.sorted(), "\(name): ranks should be in ascending order")
        }
    }

    @Test func perLanguageCuratedCollectionsDefaultToCuration() {
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greatBooksSpanish) == .curation)
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greatBooksGerman) == .curation)
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greatBooksItalian) == .curation)
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greatBooksGreek) == .curation)
    }

    // MARK: - CuratedPager

    @Test func pagerSliceFirstPage() {
        let manifest = sampleManifest(count: 60)
        let slice = CuratedPager.slice(manifest: manifest, page: 1, size: 25)
        #expect(slice.count == 25)
        #expect(slice.first?.rank == 1)
        #expect(slice.last?.rank == 25)
    }

    @Test func pagerSliceSecondPage() {
        let manifest = sampleManifest(count: 60)
        let slice = CuratedPager.slice(manifest: manifest, page: 2, size: 25)
        #expect(slice.count == 25)
        #expect(slice.first?.rank == 26)
        #expect(slice.last?.rank == 50)
    }

    @Test func pagerSliceLastPartialPage() {
        let manifest = sampleManifest(count: 60)
        let slice = CuratedPager.slice(manifest: manifest, page: 3, size: 25)
        #expect(slice.count == 10)
        #expect(slice.first?.rank == 51)
        #expect(slice.last?.rank == 60)
    }

    @Test func pagerSliceBeyondEnd() {
        let manifest = sampleManifest(count: 10)
        let slice = CuratedPager.slice(manifest: manifest, page: 2, size: 25)
        #expect(slice.isEmpty)
    }

    @Test func pagerSliceZeroPage() {
        let manifest = sampleManifest(count: 10)
        let slice = CuratedPager.slice(manifest: manifest, page: 0, size: 25)
        #expect(slice.isEmpty)
    }

    @Test func pagerOrderPreservesManifestRank() {
        let manifest = sampleManifest(count: 3)
        // Results arrive in wrong order (rank 3, 1, 2)
        let results = [
            result(id: "id3", title: "Third"),
            result(id: "id1", title: "First"),
            result(id: "id2", title: "Second")
        ]
        let ordered = CuratedPager.order(results: results, by: manifest)
        #expect(ordered.map(\.identifier) == ["id1", "id2", "id3"])
    }

    @Test func pagerOrderDropsUnknownIdentifiers() {
        let manifest = sampleManifest(count: 3)
        let results = [
            result(id: "id1", title: "First"),
            result(id: "unknown", title: "Unknown"),
            result(id: "id3", title: "Third")
        ]
        let ordered = CuratedPager.order(results: results, by: manifest)
        #expect(ordered.count == 2)
        #expect(ordered.map(\.identifier) == ["id1", "id3"])
    }

    @Test func pagerOrderStableForDuplicateRanks() {
        var entries = sampleManifest(count: 2)
        entries[1] = CuratedManifestEntry(rank: 1, title: "Book 2", author: "Author 2", identifier: "id2")
        let results = [
            result(id: "id2", title: "Second"),
            result(id: "id1", title: "First")
        ]
        let ordered = CuratedPager.order(results: results, by: entries)
        #expect(ordered.count == 2)
    }

    // MARK: - defaultSort

    @Test func curatedCollectionDefaultsToCuration() {
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greatBooks) == .curation)
        #expect(CatalogSort.defaultSort(for: IACollectionStore.greaterBooks) == .curation)
    }

    @Test func browseCollectionDefaultsToPopularity() {
        let popular = IACollectionStore.popular
        #expect(CatalogSort.defaultSort(for: popular) == .popularity)
    }

    @Test func availableSortsIncludesCurationForCurated() {
        let sorts = CatalogSort.availableSorts(for: IACollectionStore.greatBooks)
        #expect(sorts.contains(.curation))
    }

    @Test func availableSortsExcludesCurationForNonCurated() {
        let sorts = CatalogSort.availableSorts(for: IACollectionStore.popular)
        #expect(!sorts.contains(.curation))
    }

    // MARK: - CatalogSort

    @Test func curationHasNoServerSortFields() {
        #expect(CatalogSort.curation.archiveSortFields.isEmpty)
    }

    @Test func popularityHasServerSortFields() {
        #expect(!CatalogSort.popularity.archiveSortFields.isEmpty)
    }

    // MARK: - Helpers

    private func sampleManifest(count: Int) -> [CuratedManifestEntry] {
        (1...count).map { i in
            CuratedManifestEntry(
                rank: i,
                title: "Book \(i)",
                author: "Author \(i)",
                identifier: "id\(i)"
            )
        }
    }

    private func result(id: String, title: String) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: id,
            title: title,
            creators: ["Author"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: nil,
            date: nil,
            languages: ["eng"],
            subjects: []
        )
    }
}
