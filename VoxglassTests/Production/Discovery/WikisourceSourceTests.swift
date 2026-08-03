import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct WikisourceSourceTests {

    let source = WikisourceNeedsSource()

    @Test func decodesCategoryMembersIntoPracticeNeeds() throws {
        let json = """
        { "query": { "categorymembers": [
          { "pageid": 100, "title": "The Road Not Taken" },
          { "pageid": 101, "title": "Category:Poems" },
          { "pageid": 102, "title": "Author:Robert Frost" },
          { "pageid": 103, "title": "Page:Frost-1920.djvu/5" }
        ] } }
        """
        let needs = try source.decodeCategory(Data(json.utf8), clock: FixedClock())
        // Only the plain article survives; namespaced members are skipped.
        #expect(needs.count == 1)
        let need = needs.first!
        #expect(need.work.title == "The Road Not Taken")
        #expect(need.work.grade == .practice) // prefer a Gutenberg source for submittable
    }

    @Test func emptyCategoryYieldsNothing() throws {
        let needs = try source.decodeCategory(Data(#"{ "query": { "categorymembers": [] } }"#.utf8), clock: FixedClock())
        #expect(needs.isEmpty)
    }
}
