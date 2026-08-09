import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct NeedsRankerTests {

    let ranker = NeedsRanker()

    @Test func signalPriorityRules() {
        let open = makeNeed(title: "Open", signal: .openProjectNeedsReader)
        let proof = makeNeed(title: "Proof", signal: .proofListenerNeeded)
        let weekly = makeNeed(title: "Weekly", signal: .weeklyFeatured)
        let gap = makeNeed(title: "Gap", signal: .catalogGap)
        let evergreen = makeNeed(title: "Evergreen", signal: .evergreen)

        let ranked = ranker.rank([evergreen, gap, weekly, proof, open], for: .iOS)
        #expect(ranked.map(\.work.title) == ["Open", "Proof", "Weekly", "Gap", "Evergreen"])
    }

    @Test func allNeedsAreActionableOnIPhoneUnderN1() {
        // N-1: the record action is offered for every need regardless of length,
        // so length no longer gates actionability on iPhone. Both short and long
        // needs are narratable; the actionability tie-break is neutral.
        let long = makeNeed(title: "Frankenstein", author: "Mary Shelley", estSeconds: 28800)
        let short = makeNeed(title: "Hope", author: "Emily Dickinson", estSeconds: 40, signal: .evergreen)
        #expect(long.narratableOn == [.iOS, .mac])
        #expect(short.narratableOn == [.iOS, .mac])

        // Same signal → actionability tie → taste tie → short-first only applies
        // within the short rail, so the deterministic id tie-break decides.
        let ranked = ranker.rank([long, short], for: .iOS)
        #expect(Set(ranked.map(\.work.title)) == ["Frankenstein", "Hope"])
    }

    @Test func shortestFirstWithinShortRail() {
        let slow = makeNeed(title: "Long Poem", estSeconds: 3000)
        let fast = makeNeed(title: "Short Poem", estSeconds: 25)
        let mid = makeNeed(title: "Mid Poem", estSeconds: 600)
        let ranked = ranker.rank([slow, mid, fast], for: .iOS)
        #expect(ranked.map(\.work.title) == ["Short Poem", "Mid Poem", "Long Poem"])
    }

    @Test func tasteLiftsFavoritedAuthor() {
        let frost = makeNeed(title: "Fire and Ice", author: "Robert Frost")
        let dickinson = makeNeed(title: "Hope", author: "Emily Dickinson", estSeconds: 40)
        let ranked = ranker.rank([frost, dickinson], for: .iOS, taste: ["Emily Dickinson"])
        #expect(ranked.first!.work.author == "Emily Dickinson")
    }

    @Test func deterministicTieBreakByID() {
        let a = makeNeed(title: "Alpha", estSeconds: 100)
        let b = makeNeed(title: "Beta", estSeconds: 100)
        let c = makeNeed(title: "Gamma", estSeconds: 100)
        let ranked1 = ranker.rank([c, a, b], for: .iOS)
        let ranked2 = ranker.rank([b, c, a], for: .iOS)
        #expect(ranked1.map(\.id) == ranked2.map(\.id))
        #expect(ranked1.map(\.id).count == 3)
        #expect(ranked1 == ranked1.sorted { $0.id < $1.id })
    }

    @Test func longNeedsStillRankOnMac() {
        let long = makeNeed(title: "Frankenstein", author: "Mary Shelley", estSeconds: 28800)
        let short = makeNeed(title: "Hope", author: "Emily Dickinson", estSeconds: 40)
        let ranked = ranker.rank([short, long], for: .mac)
        // On Mac both are actionable; signal equal; short-first only applies within short rail.
        #expect(Set(ranked.map(\.work.title)) == ["Frankenstein", "Hope"])
    }
}
