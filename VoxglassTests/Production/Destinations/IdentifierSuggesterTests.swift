import Foundation
import Testing
import VoxglassCore

@Suite struct IdentifierSuggesterTests {

    private let suggester = IdentifierSuggester()

    @Test func suggestedFormJoinsSlugs() {
        let id = suggester.suggest(title: "The Murder of Roger Ackroyd", author: "Agatha Christie", narrator: "John Burns", year: 1926)
        #expect(id == "the_murder_of_roger_ackroyd_christie_burns")
        #expect(suggester.isValid(id))
    }

    @Test func suggestionIsLowercasedAndDeaccented() {
        let id = suggester.suggest(title: "Émile Zola", author: "André Gide", narrator: "Joël", year: nil)
        #expect(!id.contains("É"))
        #expect(!id.contains("é"))
        #expect(id.contains("emile"))
        #expect(id.contains("gide"))
    }

    @Test func suggestionTruncatesAtBoundaryWithoutTrailingSeparator() {
        let longTitle = String(repeating: "extraordinarily ", count: 20).trimmingCharacters(in: .whitespaces)
        let id = suggester.suggest(title: longTitle, author: "Author", narrator: "Narrator", year: 2026)
        #expect(id.count <= IdentifierSuggester.suggestedLengthLimit)
        #expect(!id.hasSuffix("_"))
        #expect(!id.hasPrefix("_"))
        #expect(suggester.isValid(id))
    }

    @Test func emptyInputFallsBack() {
        let id = suggester.suggest(title: "", author: "", narrator: "", year: 2026)
        #expect(id == "audiobook_2026")
        #expect(suggester.isValid(id))
    }

    @Test func validityRule() {
        #expect(suggester.isValid("murderrogerackroyd_christie_burns"))
        #expect(suggester.isValid("abcde"))
        #expect(suggester.isValid("A_B-c.1"))
        #expect(suggester.isValid("a" + String(repeating: "b", count: 79)))
        #expect(!suggester.isValid(""))
        #expect(!suggester.isValid("shor"))                  // 4 chars, minimum is 5
        #expect(!suggester.isValid("9bad id!"))              // space + punctuation
        #expect(!suggester.isValid("étoile"))                // non-ASCII
        #expect(!suggester.isValid("-starts-with-dash"))
        #expect(!suggester.isValid("a" + String(repeating: "b", count: 80)))  // 81 chars
    }

    @Test func lastWordIsUsedForNames() {
        let id = suggester.suggest(title: "Book", author: "Agatha Christie", narrator: "John Burns", year: nil)
        #expect(id == "book_christie_burns")
    }
}
