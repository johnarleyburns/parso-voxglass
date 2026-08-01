import Foundation
import Testing
import VoxglassCore

@Suite struct NormalizerTests {

    @Test func normalizeFoldsSmartQuotes() {
        let input = "He said \u{201C}hello\u{201D} and I said \u{2018}hi\u{2019}."
        let normalized = TextNormalizer.normalize(input)
        #expect(normalized.contains("\"hello\""))
        #expect(normalized.contains("'hi'"))
        #expect(!normalized.contains("\u{201C}"))
    }

    @Test func normalizeFoldsDashes() {
        let input = "A\u{2013}B \u{2014} C"
        let normalized = TextNormalizer.normalize(input)
        #expect(normalized == "A-B - C")
    }

    @Test func normalizeFoldsNBSP() {
        let input = "hello\u{00A0}world"
        let normalized = TextNormalizer.normalize(input)
        #expect(normalized == "hello world")
    }

    @Test func normalizeFoldsEllipsis() {
        let input = "Wait\u{2026} no"
        let normalized = TextNormalizer.normalize(input)
        #expect(normalized == "Wait... no")
    }

    @Test func normalizeCollapsesWhitespace() {
        let input = "  a   b \n c  "
        let normalized = TextNormalizer.normalize(input)
        #expect(normalized == "a b c")
    }

    @Test func identityKeyIsCaseInsensitive() {
        let a = TextNormalizer.identityKey("Hello World")
        let b = TextNormalizer.identityKey("hello world")
        #expect(a == b)
    }

    @Test func identityKeyStripsPunctuation() {
        let a = TextNormalizer.identityKey("Hello, world!")
        let b = TextNormalizer.identityKey("Hello world")
        #expect(a == b)
    }

    @Test func hashIsDeterministic() {
        let h1 = TextNormalizer.hash("hello world")
        let h2 = TextNormalizer.hash("hello world")
        #expect(h1 == h2)
    }

    @Test func hashIgnoresSmartQuotes() {
        let h1 = TextNormalizer.hash("He said \"hello\"")
        let h2 = TextNormalizer.hash("He said \u{201C}hello\u{201D}")
        #expect(h1 == h2)
    }

    @Test func identityKeyDiffersOnWordChange() {
        let a = TextNormalizer.identityKey("The cat sat")
        let b = TextNormalizer.identityKey("The dog sat")
        #expect(a != b)
    }

    @Test func identityKeyIgnoresCaseAndPunctuation() {
        let a = TextNormalizer.identityKey("CHAPTER ONE: The Beginning.")
        let b = TextNormalizer.identityKey("chapter one the beginning")
        #expect(a == b)
    }
}
