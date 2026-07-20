import XCTest
@testable import VoxglassCore

final class CollectionContentRulesTests: XCTestCase {

    // MARK: - Fiction rejection from nonfiction categories

    func testDraculaRejectedByScienceAndNature() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-science-nature")!
        // Dracula subjects: Gothic, Horror, Fiction, Vampires — all fiction-related
        let allowed = rules.allows(
            subjects: ["gothic fiction", "horror", "fiction", "vampires"],
            creator: "Bram Stoker",
            title: "Dracula"
        )
        XCTAssertFalse(allowed, "Dracula should be rejected by Science & Nature")
    }

    func testOriginOfSpeciesAcceptedByScienceAndNature() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-science-nature")!
        let allowed = rules.allows(
            subjects: ["life sciences", "natural history", "evolution"],
            creator: "Charles Darwin",
            title: "On the Origin of Species"
        )
        XCTAssertTrue(allowed, "On the Origin of Species should be accepted by Science & Nature")
    }

    // MARK: - General Fiction precision

    func testArtOfWarRejectedByGeneralFiction() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-general-fiction")!
        // The Art of War subjects: literature, war — no fiction subject
        let allowed = rules.allows(
            subjects: ["literature", "war"],
            creator: "Sun Tzu",
            title: "The Art of War"
        )
        XCTAssertFalse(allowed, "The Art of War should be rejected by General Fiction (no fiction subject)")
    }

    func testPrideAndPrejudiceAcceptedByGeneralFiction() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-general-fiction")!
        let allowed = rules.allows(
            subjects: ["general fiction", "romance", "literature"],
            creator: "Jane Austen",
            title: "Pride and Prejudice"
        )
        XCTAssertTrue(allowed, "Pride and Prejudice should be accepted by General Fiction")
    }

    // MARK: - Essays & Ideas precision

    func testAnthemRejectedByEssaysAndIdeas() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-essays-ideas")!
        // Anthem subjects: science fiction, dystopian — fiction genre
        let allowed = rules.allows(
            subjects: ["science fiction", "dystopian", "novel"],
            creator: "Ayn Rand",
            title: "Anthem"
        )
        XCTAssertFalse(allowed, "Anthem (fiction) should be rejected by Essays & Ideas")
    }

    func testWaldenAcceptedByEssaysAndIdeas() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-essays-ideas")!
        let allowed = rules.allows(
            subjects: ["essays", "nature", "literary criticism"],
            creator: "Henry David Thoreau",
            title: "Walden"
        )
        XCTAssertTrue(allowed, "Walden should be accepted by Essays & Ideas")
    }

    func testPhilosophyMonographRejectedByEssaysAndIdeas() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-essays-ideas")!
        // A philosophy monograph — tagged with philosophy subjects
        let allowed = rules.allows(
            subjects: ["epistemology", "philosophy", "ethics"],
            creator: "Immanuel Kant",
            title: "Critique of Pure Reason"
        )
        XCTAssertFalse(allowed, "Philosophy monograph should be rejected by Essays & Ideas")
    }

    // MARK: - War & Military precision

    func testLittleWomenRejectedByWarAndMilitary() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-war-military")!
        let allowed = rules.allows(
            subjects: ["general fiction", "family life", "domestic fiction"],
            creator: "Louisa May Alcott",
            title: "Little Women"
        )
        XCTAssertFalse(allowed, "Little Women (no war subject) should be rejected by War & Military")
    }

    func testArtOfWarAcceptedByWarAndMilitary() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-war-military")!
        let allowed = rules.allows(
            subjects: ["war", "strategy & tactics", "military"],
            creator: "Sun Tzu",
            title: "The Art of War"
        )
        XCTAssertTrue(allowed, "The Art of War should be accepted by War & Military")
    }

    func testAbrahamLincolnBiographyRejectedByWarAndMilitary() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-war-military")!
        let allowed = rules.allows(
            subjects: ["biography & autobiography", "war", "civil war"],
            creator: "John George Nicolay",
            title: "A Short Life of Abraham Lincoln"
        )
        XCTAssertFalse(allowed, "Biography-tagged item should be rejected by War & Military even if it has war subject")
    }

    // MARK: - Global title pattern exclusions

    func testShortNonfictionCollectionRejectedEverywhere() {
        let title = "Short Nonfiction Collection 012"
        for collectionID in ["lv-general-fiction", "lv-science-nature", "lv-history", "lv-essays-ideas"] {
            guard let rules = CollectionRulesRegistry.rules(forCollectionID: collectionID) else { continue }
            let allowed = rules.allows(
                subjects: ["non-fiction", "essays", "science"],
                creator: "Various",
                title: title
            )
            XCTAssertFalse(allowed, "'\(title)' should be rejected by \(collectionID)")
        }
    }

    func testShortStoryCollectionRejectedByScienceAndNature() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-science-nature")!
        let allowed = rules.allows(
            subjects: ["short stories", "fiction"],
            creator: "Various",
            title: "Short Story Collection 045"
        )
        XCTAssertFalse(allowed, "Short Story Collection should be rejected by Science & Nature")
    }

    // MARK: - Normalization edge cases

    func testNonFictionDoesNotMatchFictionExclusion() {
        let rules = CollectionRulesRegistry.rules(forCollectionID: "lv-general-fiction")!
        // "non-fiction" is NOT confused with "fiction" in requireAnySubjects
        // (the require set has "fiction" which does not match "non-fiction")
        let allowedComplex = rules.allows(
            subjects: ["general fiction", "non-fiction", "historical fiction"],
            creator: "Author Name",
            title: "Some Non-Fiction Book"
        )
        // "non-fiction" in excludeSubjects blocks it — that's an explicit exclusion
        XCTAssertFalse(allowedComplex, "Non-fiction tag should be excluded from General Fiction per explicit exclude rule")
        // But a subject of "fiction" (without non-) satisfies the require
        let allowedFiction = rules.allows(
            subjects: ["general fiction", "historical fiction"],
            creator: "Author Name",
            title: "A Fiction Book"
        )
        XCTAssertTrue(allowedFiction, "Fiction-tagged book should be accepted by General Fiction")
    }

    // MARK: - Collection ID migration

    func testDecodeCollectionIDsDropsLiteraryFiction() {
        let result = AppPreferencesStore.decodeCollectionIDs("lv-literary-fiction,lv-poetry")
        XCTAssertFalse(result.contains("lv-literary-fiction"))
        XCTAssertTrue(result.contains("lv-poetry"))
    }

    func testDecodeCollectionIDsMapsAncientGreeceToAncientWorld() {
        let result = AppPreferencesStore.decodeCollectionIDs("ancient-greece,lv-poetry")
        XCTAssertFalse(result.contains("ancient-greece"))
        XCTAssertTrue(result.contains("lv-ancient-world"))
        XCTAssertTrue(result.contains("lv-poetry"))
    }

    func testDecodeCollectionIDsIsIdempotent() {
        let first = AppPreferencesStore.decodeCollectionIDs("lv-literary-fiction,ancient-greece")
        let second = AppPreferencesStore.decodeCollectionIDs("lv-literary-fiction,ancient-greece")
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("lv-literary-fiction"))
        XCTAssertFalse(first.contains("ancient-greece"))
        XCTAssertTrue(first.contains("lv-ancient-world"))
    }
}
