import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Exhaustive unit tests for `FilenameSanitizer` (§16.5): the spec's table, the
/// LibriVox composition rule, and a 1,000-title Unicode fuzz that must always
/// yield `[a-z0-9_]+` of length ≤ 100 (§19.3).
///
/// > The spec's table lists `"The Murder of Roger Ackroyd"` → `themurderofrogerackroyd`
/// > (words concatenated), which contradicts the same section's algorithm (step 3:
/// > runs outside `[a-z0-9]` become a single `_`) and its own `emile_zola` /
/// > `l_assommoir` rows. The algorithm governs (§22.10); the deviation is
/// > recorded in the `FilenameSanitizer` doc comment.
@Suite struct FilenameSanitizerTests {

    private let sanitizer = FilenameSanitizer()

    @Test func specTableSanitizerCases() {
        #expect(sanitizer.sanitize("The Murder of Roger Ackroyd", rule: .librivoxLowercaseNoSpace) == "the_murder_of_roger_ackroyd")
        #expect(sanitizer.sanitize("Émile Zola", rule: .librivoxLowercaseNoSpace) == "emile_zola")
        #expect(sanitizer.sanitize("L'Assommoir", rule: .librivoxLowercaseNoSpace) == "l_assommoir")
        #expect(sanitizer.sanitize("A Tale of Two Cities", rule: .librivoxLowercaseNoSpace) == "a_tale_of_two_cities")
    }

    @Test func punctuationOnlyTitleFallsBackToBook() {
        #expect(sanitizer.sanitize("!!!***", rule: .librivoxLowercaseNoSpace) == "book")
        #expect(sanitizer.sanitize("——", rule: .librivoxLowercaseNoSpace) == "book")
        #expect(sanitizer.sanitize("", rule: .librivoxLowercaseNoSpace) == "book")
    }

    @Test func cjkTitleFallsBackToBook() {
        #expect(sanitizer.sanitize("日本語の本", rule: .librivoxLowercaseNoSpace) == "book")
    }

    @Test func longTitleIsCappedAt100Characters() {
        let longTitle = String(repeating: "Word ", count: 40).trimmingCharacters(in: .whitespaces)
        let result = sanitizer.sanitize(longTitle, rule: .librivoxLowercaseNoSpace)
        #expect(result.count <= 100)
        #expect(result.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" })
    }

    @Test func fuzzThousandUnicodeTitlesStayValid() {
        let pool = Array("abcXYZ019 !?.,'éâ中文—…ß😀\u{0301}\u{0300}")
        for _ in 0..<1_000 {
            let length = Int(SimplePRNG.next() % 60)
            var title = ""
            for _ in 0..<length {
                title.append(pool[Int(SimplePRNG.next() % UInt64(pool.count))])
            }
            let result = sanitizer.sanitize(title, rule: .librivoxLowercaseNoSpace)
            #expect(result.count <= 100)
            #expect(result.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil)
        }
    }

    @Test func librivoxFilenameComposition() {
        #expect(sanitizer.librivoxFilename(shortTitle: "The Murder of Roger Ackroyd", section: 1, sectionCount: 12, authorLastName: "Christie")
                == "the_murder_of_roger_01_christie")
        #expect(sanitizer.librivoxFilename(shortTitle: "Émile Zola", section: 7, sectionCount: 9, authorLastName: "Zola")
                == "emile_zola_07_zola")
    }

    @Test func sectionPaddingIsMinimumWidthTwo() {
        #expect(sanitizer.librivoxFilename(shortTitle: "Chapter", section: 7, sectionCount: 9, authorLastName: "a")
                == "chapter_07_a")
        #expect(sanitizer.librivoxFilename(shortTitle: "Chapter", section: 100, sectionCount: 120, authorLastName: "a")
                == "chapter_100_a")
        #expect(sanitizer.librivoxFilename(shortTitle: "Chapter", section: 1, sectionCount: 1, authorLastName: "a")
                == "chapter_01_a")
    }

    @Test func librivoxFilenameFallsBackToBookForEmptySlug() {
        #expect(sanitizer.librivoxFilename(shortTitle: "!!!", section: 1, sectionCount: 5, authorLastName: "Doe")
                == "book_01_doe")
    }

    @Test func librivoxFilenameTruncatesShortTitleAtBoundary() {
        // 28-char slug truncated to ≤ 24 at the nearest `_` boundary → 19 chars.
        let name = sanitizer.librivoxFilename(shortTitle: "The Murder of Roger Ackroyd", section: 1, sectionCount: 12, authorLastName: "Christie")
        #expect(name.hasPrefix("the_murder_of_roger_01_"))
        #expect(name.count <= 100)
    }

    @Test func archiveFilenameComposition() {
        #expect(sanitizer.archiveFilename(identifier: "ackroyd_christie_burns", section: 1, sectionCount: 12, chapterTitle: "Breakfast Table", ext: "flac")
                == "ackroyd_christie_burns_01_breakfast_table.flac")
        #expect(sanitizer.archiveFilename(identifier: "id", section: 2, sectionCount: 12, chapterTitle: "Who's Who in King's Abbot", ext: "mp3")
                == "id_02_whos_who_in_kings_abbot.mp3")
    }

    @Test func freeformNumberedComposition() {
        #expect(sanitizer.freeformNumbered(section: 1, sectionCount: 12, chapterTitle: "Opening Credits", ext: "mp3")
                == "01 - Opening Credits.mp3")
        #expect(sanitizer.freeformNumbered(section: 12, sectionCount: 12, chapterTitle: "The End", ext: "wav")
                == "12 - The End.wav")
    }

    @Test func freeformRuleStripsPathIllegalCharacters() {
        let result = sanitizer.sanitize("Chapter / One: Revisited", rule: .freeformNumbered)
        #expect(!result.contains("/"))
        #expect(!result.contains(":"))
    }
}
