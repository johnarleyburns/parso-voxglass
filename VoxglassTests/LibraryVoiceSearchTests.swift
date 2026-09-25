import Foundation
import Testing
@testable import VoxglassCore

@Suite struct LibraryVoiceSearchTests {
    private let odyssey = LibraryVoiceSearch.Candidate(
        id: UUID(), title: "The Odyssey", authorLine: "Homer",
        authors: ["Homer"], narrators: ["Emily Wilson"]
    )
    private let iliad = LibraryVoiceSearch.Candidate(
        id: UUID(), title: "The Iliad", authorLine: "Homer",
        authors: ["Homer"], narrators: ["Dan Stevens"]
    )
    private let dracula = LibraryVoiceSearch.Candidate(
        id: UUID(), title: "Dracula", authorLine: "Bram Stoker",
        authors: ["Bram Stoker"], narrators: ["Greg Wagland"]
    )

    private var all: [LibraryVoiceSearch.Candidate] { [odyssey, iliad, dracula] }

    @Test func matchesTitleAuthorAndNarrator() {
        #expect(LibraryVoiceSearch.rank(query: "odyssey", candidates: all) == [odyssey.id])
        #expect(Set(LibraryVoiceSearch.rank(query: "homer", candidates: all)) == [odyssey.id, iliad.id])
        #expect(LibraryVoiceSearch.rank(query: "emily wilson", candidates: all) == [odyssey.id])
    }

    /// Spoken requests carry connective words a strict AND would trip on.
    @Test func ignoresFillerWordsInSpokenQueries() {
        #expect(LibraryVoiceSearch.rank(query: "the odyssey by homer", candidates: all) == [odyssey.id])
        #expect(LibraryVoiceSearch.tokens("the odyssey by homer") == ["odyssey", "homer"])
    }

    @Test func keepsFillerWhenTheWholeQueryIsFiller() {
        #expect(LibraryVoiceSearch.tokens("The") == ["the"])
    }

    @Test func titleMatchesOutrankAuthorOnlyMatches() {
        let homerBiography = LibraryVoiceSearch.Candidate(
            id: UUID(), title: "Homer: A Life", authorLine: "Someone Else",
            authors: ["Someone Else"], narrators: []
        )
        let ranked = LibraryVoiceSearch.rank(query: "homer", candidates: all + [homerBiography])
        #expect(ranked.first == homerBiography.id)
    }

    @Test func strictModeReturnsNothingWhenAnyTokenMisses() {
        #expect(LibraryVoiceSearch.rank(query: "odyssey stoker", candidates: all).isEmpty)
    }

    /// Siri transcriptions mangle names ("emily willson"); the partial fallback
    /// still finds the book that matches the rest of the request.
    @Test func partialFallbackRanksByTokensMatched() {
        let ranked = LibraryVoiceSearch.rank(query: "odyssey emily willson", candidates: all, allowPartial: true)
        #expect(ranked.first == odyssey.id)
    }

    @Test func partialFallbackIsOnlyUsedWhenNothingMatchesEveryToken() {
        let ranked = LibraryVoiceSearch.rank(query: "homer", candidates: all, allowPartial: true)
        #expect(Set(ranked) == [odyssey.id, iliad.id])
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(LibraryVoiceSearch.rank(query: "  ", candidates: all, allowPartial: true).isEmpty)
    }
}
