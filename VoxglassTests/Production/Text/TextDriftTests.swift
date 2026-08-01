import Foundation
import Testing
import VoxglassCore

@Suite struct TextDriftTests {

    @Test func identicalTextIsNone() {
        let detector = TextDriftDetector()
        let kind = detector.classify(recorded: "Hello world", current: "Hello world")
        #expect(kind == .none)
    }

    @Test func punctuationOnlyIsCosmetic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(recorded: "Hello world.", current: "Hello, world!")
        #expect(kind == .cosmetic)
    }

    @Test func caseChangeIsCosmetic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(recorded: "HELLO WORLD", current: "hello world")
        #expect(kind == .cosmetic)
    }

    @Test func oneWordEditOnLongTextIsMinor() {
        let detector = TextDriftDetector()
        let base = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 10).joined(separator: " ")
        var words = base.components(separatedBy: " ")
        words[1] = "fast"
        let edited = words.joined(separator: " ")
        let kind = detector.classify(recorded: base, current: edited)
        #expect(kind == .minor)
    }

    @Test func twoWordEditsOnLongTextIsMinor() {
        let detector = TextDriftDetector()
        let base = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 10).joined(separator: " ")
        var words = base.components(separatedBy: " ")
        words[1] = "fast"
        words[7] = "sleepy"
        let edited = words.joined(separator: " ")
        let kind = detector.classify(recorded: base, current: edited)
        #expect(kind == .minor)
    }

    @Test func majorChangeIsSemantic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(
            recorded: "The quick brown fox jumps over the lazy dog",
            current: "A completely different sentence about something else entirely"
        )
        #expect(kind == .semantic)
    }

    @Test func numberChangeIsAlwaysSemantic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(
            recorded: "There are 5 books on the shelf",
            current: "There are 3 books on the shelf"
        )
        #expect(kind == .semantic)
    }

    @Test func numberWordChangeIsAlwaysSemantic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(
            recorded: "He knocked three times",
            current: "He knocked four times"
        )
        #expect(kind == .semantic)
    }

    @Test func numberWordRemovalIsAlwaysSemantic() {
        let detector = TextDriftDetector()
        let kind = detector.classify(
            recorded: "There were twenty soldiers",
            current: "There were soldiers"
        )
        #expect(kind == .semantic)
    }

    @Test func identityKeyPreservesDigits() {
        #expect(TextNormalizer.identityKey("Chapter 3") != TextNormalizer.identityKey("Chapter 4"))
        #expect(TextNormalizer.identityKey("Chapter 3") == TextNormalizer.identityKey("Chapter 3"))
    }
}
