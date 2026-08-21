import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct NarrationHomeShelfPlanTests {

    @Test func featuredWorkIsExcludedFromBothRails() {
        let featured = makeNeed(title: "Featured Work", author: "One Author", estSeconds: 60, text: "text")
        let shortDuplicate = makeNeed(
            title: "Featured Work", author: "One Author", estSeconds: 120,
            host: "archive.org", text: "different source text"
        )
        let longDuplicate = makeNeed(
            title: "Featured Work", author: "One Author", estSeconds: 4_000,
            host: "wikisource.org", text: "another source text"
        )

        let plan = NarrationHomeShelfPlan(
            needs: [shortDuplicate, longDuplicate],
            featured: featured
        )

        #expect(plan.featured?.workIdentity == featured.workIdentity)
        #expect(!plan.short.contains { $0.workIdentity == featured.workIdentity })
        #expect(!plan.long.contains { $0.workIdentity == featured.workIdentity })
    }

    @Test func duplicateSourceRowsCollapseBeforeRailLimits() {
        let duplicateShort = makeNeed(title: "Same Work", author: "Same Author", text: "text")
        let duplicateLong = makeNeed(
            title: "Same Work", author: "Same Author", estSeconds: 4_000,
            host: "archive.org", text: "text"
        )
        let other = makeNeed(title: "Other Work", author: "Other Author", text: "text")

        let plan = NarrationHomeShelfPlan(
            needs: [duplicateShort, duplicateLong, other],
            featured: nil
        )

        #expect(plan.short.map(\.workIdentity) == [other.workIdentity])
        #expect(plan.long.isEmpty)
        #expect(plan.featured?.workIdentity == duplicateShort.workIdentity)
    }

    @Test func similarTitlesByDifferentAuthorsRemainDistinct() {
        let first = makeNeed(title: "The Home", author: "First Author", text: "text")
        let second = makeNeed(title: "The Home", author: "Second Author", text: "text")

        let plan = NarrationHomeShelfPlan(needs: [first, second], featured: nil)

        #expect(plan.featured?.workIdentity == first.workIdentity)
        #expect(plan.short.map(\.workIdentity) == [second.workIdentity])
    }
}
