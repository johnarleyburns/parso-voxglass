import Foundation
import Testing
@testable import VoxglassCore

@Suite struct CollectionQueryHygieneTests {

    private static let denylistedBareSubjects: Set<String> = [
        "Fiction", "Science", "Nature", "War", "Military",
        "Literature", "Novels", "Novel"
    ]

    private static let nonfictionCategoryIDs: Set<String> = [
        "lv-travel", "lv-ancient-world", "lv-philosophy-mind",
        "lv-history", "lv-biography", "lv-science-nature",
        "lv-religion", "lv-essays-ideas"
    ]

    @Test func noBareDenylistedSubjectTokensInAnyCategoryQuery() {
        let barePattern = "subject:([A-Z][a-zA-Z]*)"
        guard let regex = try? NSRegularExpression(pattern: barePattern) else {
            Issue.record("Could not create regex")
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
                    Issue.record("Category '\(category.id)' contains bare denylisted subject token '\(token)'")
                }
            }
        }
    }

    @Test func noTitleClausesInNonfictionCategoryQueries() {
        for category in LibriVoxBrowseGroup.categories {
            guard Self.nonfictionCategoryIDs.contains(category.id) else { continue }
            let positive = positiveClause(of: category.archiveQuery)
            if positive.contains("title:") {
                Issue.record("Nonfiction category '\(category.id)' contains a title: clause: \(category.archiveQuery)")
            }
        }
    }

    @Test func scienceNatureQueryHasNoFictionSubjects() {
        let query = LibriVoxBrowseCategory.scienceNature.archiveQuery
        #expect(query.contains("subject:\"Life Sciences\""))
        #expect(query.contains("subject:\"Astronomy, Physics & Mechanics\""))
        #expect(!(query.contains("Nature & Animal Fiction")))
        #expect(!(query.contains("subject:Science")))
        #expect(!(query.contains("subject:Nature")))
    }

    @Test func essaysIdeasQueryHasNoPhilosophyOrTitleClauses() {
        let query = LibriVoxBrowseCategory.essaysIdeas.archiveQuery
        let positive = positiveClause(of: query)
        #expect(!(positive.contains("subject:\"Philosophy\"")))
        #expect(!(positive.contains("title:essay")))
        #expect(!(positive.contains("title:lectures")))
        #expect(!(positive.contains("title:letters")))
    }

    @Test func warMilitaryQueryUsesOnlyQuotedPhrases() {
        let query = LibriVoxBrowseCategory.warMilitary.archiveQuery
        let positive = positiveClause(of: query)
        #expect(positive.contains("subject:\"War & Military Fiction\""))
        #expect(positive.contains("subject:\"World War, 1914-1918\""))
        // Must not have bare subject:War or subject:Military (outside quotes).
        #expect(!(positive.contains("subject:War ")))
        #expect(!(positive.contains("subject:Military ")))
        #expect(!(positive.contains("subject:Espionage")))
        #expect(!(positive.contains("subject:Thrillers")))
    }

    @Test func ancientWorldQueryHasNoTitleClauses() {
        let query = LibriVoxBrowseCategory.ancientWorld.archiveQuery
        let positive = positiveClause(of: query)
        #expect(!(positive.contains("title:ancient")))
        #expect(!(positive.contains("title:greece")))
        #expect(!(positive.contains("title:greek")))
        #expect(!(positive.contains("title:rome")))
        #expect(!(positive.contains("title:roman")))
    }

    @Test func literaryFictionIsNotInBrowseGroup() {
        #expect(LibriVoxBrowseCategory.category(withID: "lv-literary-fiction") == nil)
        let allIDs = LibriVoxBrowseGroup.categories.map(\.id)
        #expect(!(allIDs.contains("lv-literary-fiction")))
    }

    private func positiveClause(of query: String) -> String {
        guard let range = query.range(of: " AND NOT ") else { return query }
        return String(query[query.startIndex..<range.lowerBound])
    }
}
