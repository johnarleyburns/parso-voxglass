import Foundation
import Testing
import VoxglassCore

@Suite struct LengthClassTests {

    @Test func boundaryAtShortWorkCeiling() {
        // LibriVox's definition: short works are less than 1 hour read by individuals.
        #expect(LengthClass.classification(forEstSeconds: 3599) == .short)
        #expect(LengthClass.classification(forEstSeconds: 3600) == .short) // boundary is short
        #expect(LengthClass.classification(forEstSeconds: 3601) == .long)
        #expect(LengthClass.classification(forEstSeconds: 3660) == .long) // 61 minutes
    }

    @Test func narratableOnIsDerived() {
        let short = makeNeed(title: "Poem", estSeconds: 40)
        let long = makeNeed(title: "Book", estSeconds: 28800)
        #expect(short.narratableOn == [.iOS, .mac])
        #expect(long.narratableOn == [.mac])
    }

    @Test func derivedInWorkInit() {
        let short = NarratableWork(title: "A", author: "B", estSeconds: 3000)
        let long = NarratableWork(title: "C", author: "D", estSeconds: 7200)
        #expect(short.lengthClass == .short)
        #expect(long.lengthClass == .long)
    }

    @Test func needIDIsStableAndHostSensitive() {
        let a = NeedID.compute(author: "Emily Dickinson", title: "Hope", sourceHost: "gutenberg.org")
        let b = NeedID.compute(author: "EMILY DICKINSON", title: "  hope  ", sourceHost: "Gutenberg.org")
        let c = NeedID.compute(author: "Emily Dickinson", title: "Hope", sourceHost: "forum.librivox.org")
        #expect(a == b)
        #expect(a != c)
    }
}
