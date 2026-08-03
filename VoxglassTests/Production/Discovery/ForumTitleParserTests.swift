import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct ForumTitleParserTests {

    let parser = ForumTitleParser()

    @Test func weeklyPoetryThread() {
        let parsed = parser.parse("[WEEKLY POETRY] - Hope is the thing with feathers by Emily Dickinson")
        #expect(parsed.isWeeklyPoem)
        #expect(parsed.isNarratable)
        #expect(parsed.title == "Hope is the thing with feathers")
        #expect(parsed.author == "Emily Dickinson")
    }

    @Test func openUSOnlyDRThread() {
        let parsed = parser.parse("[OPEN - US ONLY] [DR] - The House of the Seven Gables by Nathaniel Hawthorne")
        #expect(parsed.usOnly)
        #expect(parsed.status == .openNeedsReader)
        #expect(parsed.isNarratable)
        #expect(parsed.author == "Nathaniel Hawthorne")
    }

    @Test func proofListenerNeededThread() {
        let parsed = parser.parse("~[GROUP] - A Collection of Essays")
        #expect(parsed.status == .proofListenerNeeded)
        #expect(parsed.isNarratable)
    }

    @Test func soloOpenThread() {
        let parsed = parser.parse("[SOLO] [OPEN] - The Time Machine by H. G. Wells")
        #expect(parsed.isNarratable)
        #expect(parsed.title == "The Time Machine")
        #expect(parsed.author == "H. G. Wells")
    }

    @Test func completeThreadIsSkipped() {
        let parsed = parser.parse("COMPLETE [SOLO] - Pride and Prejudice by Jane Austen")
        #expect(!parsed.isNarratable)
        #expect(parsed.status == .full)
    }

    @Test func fullThreadIsSkipped() {
        let parsed = parser.parse("[FULL] [GROUP] - Moby Dick")
        #expect(!parsed.isNarratable)
        #expect(parsed.status == .full)
    }
}
