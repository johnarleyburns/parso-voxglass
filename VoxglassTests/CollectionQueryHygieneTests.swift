import XCTest
@testable import VoxglassCore

final class CollectionQueryHygieneTests: XCTestCase {

    private static let denylistedBareSubjects: Set<String> = [
        "Fiction", "Science", "Nature", "War", "Military",
        "Literature", "Novels", "Novel"
    ]

    private static let nonfictionCategoryIDs: Set<String> = [
        "lv-travel", "lv-ancient-world", "lv-philosophy-mind",
        "lv-history", "lv-biography", "lv-science-nature",
        "lv-religion", "lv-essays-ideas"
    ]

    func testNoBareDenylistedSubjectTokensInAnyCategoryQuery() {
        let barePattern = "subject:([A-Z][a-zA-Z]*)"
        guard let regex = try? NSRegularExpression(pattern: barePattern) else {
            XCTFail("Could not create regex")
            return
        }

        for category in LibriVoxBrowseGroup.categories {
            let query = category.archiveQuery
            // Strip everything after AND NOT so we only check positive clauses.
            let positive = positiveClause(of: query)
            let range = NSRange(positive.startIndex..., in: positive)
            regex.enumerateMatches(in: positive, range: range) { match, _, _ in
                guard let match,
                      let swiftRange = Range(match.range(at: 1), in: positive) else { return }
                let token = String(positive[swiftRange])
                if Self.denylistedBareSubjects.contains(token) {
                    XCTFail("Category '\(category.id)' contains bare denylisted subject token '\(token)'")
                }
            }
        }
    }

    func testNoTitleClausesInNonfictionCategoryQueries() {
        for category in LibriVoxBrowseGroup.categories {
            guard Self.nonfictionCategoryIDs.contains(category.id) else { continue }
            let positive = positiveClause(of: category.archiveQuery)
            if positive.contains("title:") {
                XCTFail("Nonfiction category '\(category.id)' contains a title: clause: \(category.archiveQuery)")
            }
        }
    }

    func testScienceNatureQueryHasNoFictionSubjects() {
        let query = LibriVoxBrowseCategory.scienceNature.archiveQuery
        XCTAssertTrue(query.contains("subject:\"Life Sciences\""))
        XCTAssertTrue(query.contains("subject:\"Astronomy, Physics & Mechanics\""))
        XCTAssertFalse(query.contains("Nature & Animal Fiction"))
        XCTAssertFalse(query.contains("subject:Science"))
        XCTAssertFalse(query.contains("subject:Nature"))
    }

    func testEssaysIdeasQueryHasNoPhilosophyOrTitleClauses() {
        let query = LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        let positive = positiveClause(of: query)
        XCTAssertFalse(positive.contains("subject:\"Philosophy\""))
        XCTAssertFalse(positive.contains("title:essay"))
        XCTAssertFalse(positive.contains("title:lectures"))
        XCTAssertFalse(positive.contains("title:letters"))
    }

    func testWarMilitaryQueryUsesOnlyQuotedPhrases() {
        let query = LibriVoxBrowseCategory.warMilitary.archiveQuery
        let positive = positiveClause(of: query)
        XCTAssertTrue(positive.contains("subject:\"War & Military Fiction\""))
        XCTAssertTrue(positive.contains("subject:\"World War, 1914-1918\""))
        // Must not have bare subject:War or subject:Military (outside quotes).
        XCTAssertFalse(positive.contains("subject:War "))
        XCTAssertFalse(positive.contains("subject:Military "))
        XCTAssertFalse(positive.contains("subject:Espionage"))
        XCTAssertFalse(positive.contains("subject:Thrillers"))
    }

    func testAncientWorldQueryHasNoTitleClauses() {
        let query = LibriVoxBrowseCategory.ancientWorld.archiveQuery
        let positive = positiveClause(of: query)
        XCTAssertFalse(positive.contains("title:ancient"))
        XCTAssertFalse(positive.contains("title:greece"))
        XCTAssertFalse(positive.contains("title:greek"))
        XCTAssertFalse(positive.contains("title:rome"))
        XCTAssertFalse(positive.contains("title:roman"))
    }

    func testLiteraryFictionIsNotInBrowseGroup() {
        XCTAssertNil(LibriVoxBrowseCategory.category(withID: "lv-literary-fiction"))
        let allIDs = LibriVoxBrowseGroup.categories.map(\.id)
        XCTAssertFalse(allIDs.contains("lv-literary-fiction"))
    }

    private func positiveClause(of query: String) -> String {
        guard let range = query.range(of: " AND NOT ") else { return query }
        return String(query[query.startIndex..<range.lowerBound])
    }
}
