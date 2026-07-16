import Foundation

/// Pure display-string logic for per-chapter narrator lines. Lives in Core so it
/// is covered by `swift test`; the view layer only renders the returned string.
public enum NarratorDisplay {
    /// The narrator line to show for a chapter, or `nil` when it would be
    /// redundant (single-narrator book) or empty (chapter has no narrators).
    public static func chapterLine(chapter: Chapter, bookNarrators: [String]) -> String? {
        guard !chapter.narrators.isEmpty else { return nil }
        let uniqueBookNarrators = Set(bookNarrators)
        if uniqueBookNarrators.count <= 1 { return nil }
        return chapter.narrators.joined(separator: ", ")
    }
}
