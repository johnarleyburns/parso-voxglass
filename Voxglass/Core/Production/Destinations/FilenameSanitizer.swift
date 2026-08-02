import Foundation

/// Pure, exhaustively-unit-tested filename construction (§3.2.4, §16.5).
///
/// The LibriVox rule (`librivoxLowercaseNoSpace`) is the riskiest because
/// filenames are part of the project's submission contract and a wrong name is
/// an immediate rejection. The algorithm is specified exactly in §16.5:
///
/// 1. Unicode-decompose and strip combining marks (`é` → `e`, `ß` → `ss`).
/// 2. Lowercase.
/// 3. Replace any run of characters outside `[a-z0-9]` with a single `_`.
/// 4. Trim leading/trailing `_`.
/// 5. Collapse repeated `_`.
/// 6. Truncate `shortTitle` to 24 characters at a `_` boundary where possible.
/// 7. Compose `\(shortTitle)_\(zeroPadded(section))_\(authorLastName)`.
/// 8. Reject (assert in tests) any result outside `[a-z0-9_]` or > 100 chars.
///
/// Section padding is always minimum width 2 (`07`), expanding to three digits
/// at 100+ sections (LibriVox templates conventionally use two digits).
///
/// > **Deviation from the spec's §16.5 test table.** The table lists
/// > `"The Murder of Roger Ackroyd"` → `themurderofrogerackroyd` (words
/// > concatenated), which contradicts the same section's algorithm step 3 and
/// > its own `emile_zola` / `l_assommoir` rows (words `_`-joined). The worked
/// > artifact (§16.13) uses a user-chosen short title `murderrogerackroyd`, so
/// > the concatenated form comes from the project's filename template, not from
/// > this sanitizer. The algorithm is followed here: words are `_`-joined, so
/// > `sanitize("The Murder of Roger Ackroyd")` is `the_murder_of_roger_ackroyd`.
public struct FilenameSanitizer: Sendable {

    public init() {}

    /// The truncation budget for a LibriVox short title, per §16.5 step 6.
    public static let librivoxShortTitleLimit = 24

    /// Hard cap on a `sanitize`d slug so the fuzz contract (`[a-z0-9_]+`,
    /// ≤ 100 chars) always holds (§16.5 step 8 / §19.3).
    public static let maximumSlugLength = 100

    /// Sanitize `raw` for the given rule.
    ///
    /// - `.librivoxLowercaseNoSpace`: the §16.5 algorithm (lowercase, diacritic
    ///   stripped, `_`-joined), capped at 100 characters so the fuzz contract
    ///   (`[a-z0-9_]+`, ≤ 100) always holds. A title that sanitizes to nothing
    ///   (punctuation-only, or non-Latin script — transliteration is out of
    ///   scope) falls back to `"book"`.
    /// - `.archiveIdentifierPrefixed`: a lowercase slug for chapter titles
    ///   (`[a-z0-9_]+`), safe to embed in `<identifier>_NN_<slug>.<ext>`.
    /// - `.freeformNumbered`: path-safe but human readable — keeps case and
    ///   spaces, drops characters illegal in macOS filenames.
    public func sanitize(_ raw: String, rule: FilenameRule) -> String {
        switch rule {
        case .librivoxLowercaseNoSpace:
            let slug = librivoxSlug(raw)
            let fallback = slug.isEmpty ? "book" : slug
            return truncateAtBoundary(fallback, to: Self.maximumSlugLength)
        case .archiveIdentifierPrefixed:
            return slugify(raw, allowed: asciiAlphanumerics, separator: "_", lowercase: true)
        case .freeformNumbered:
            let illegal = CharacterSet(charactersIn: "/:\\")
                .union(.newlines)
                .union(.controlCharacters)
            return raw.components(separatedBy: illegal)
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `murderrogerackroyd_01_christie.mp3`-style names (§3.2.4). The short
    /// title is truncated to 24 characters at a `_` boundary (§16.5 step 6).
    public func librivoxFilename(shortTitle: String, section: Int, sectionCount: Int, authorLastName: String) -> String {
        let slug = librivoxSlug(shortTitle)
        let title = truncateShortTitle(slug.isEmpty ? "book" : slug)
        let padded = zeroPadded(section, sectionCount: sectionCount)
        return "\(title)_\(padded)_\(librivoxSlug(authorLastName))"
    }

    /// `<identifier>_NN_<slug>.<ext>` (§3.3.3). Apostrophes are removed, not
    /// turned into separators ("Who's Who" → `whos_who`), so chapter slugs read
    /// naturally inside an archive identifier-style filename.
    public func archiveFilename(identifier: String, section: Int, sectionCount: Int, chapterTitle: String, ext: String) -> String {
        let padded = zeroPadded(section, sectionCount: sectionCount)
        let stripped = chapterTitle
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
        let slug = slugify(stripped, allowed: asciiAlphanumerics, separator: "_", lowercase: true)
        let name = slug.isEmpty ? "chapter" : slug
        return "\(identifier)_\(padded)_\(name).\(ext)"
    }

    /// `NN - Chapter Title.<ext>` (§3.4.2 / §16.8).
    public func freeformNumbered(section: Int, sectionCount: Int, chapterTitle: String, ext: String) -> String {
        let padded = zeroPadded(section, sectionCount: sectionCount)
        let cleaned = sanitize(chapterTitle, rule: .freeformNumbered)
        return "\(padded) - \(cleaned).\(ext)"
    }

    // MARK: - Private helpers

    /// ASCII-only `[a-zA-Z0-9]` — §16.5 step 3 is explicitly `[a-z0-9]`, and a
    /// non-ASCII title (e.g. CJK) must fall back to `book`, not be transliterated.
    private let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Step-by-step §16.5 algorithm: diacritics → lowercase → `[a-z0-9]`
    /// runs collapsed to a single `_`.
    private func librivoxSlug(_ raw: String) -> String {
        let deaccented = stripDiacritics(raw)
        let lower = deaccented.lowercased()
        var pieces: [String] = []
        var current = ""
        for scalar in lower.unicodeScalars {
            if asciiAlphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { pieces.append(current); current = "" }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.joined(separator: "_")
    }

    /// Generic slug: reduce `raw` to ASCII alphanumerics joined by `separator`,
    /// optionally lowercased, runs collapsed.
    private func slugify(_ raw: String, allowed: CharacterSet, separator: String, lowercase: Bool) -> String {
        let source = lowercase ? raw.lowercased() : raw
        let deaccented = lowercase ? stripDiacritics(source) : source
        var pieces: [String] = []
        var current = ""
        for scalar in deaccented.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { pieces.append(current); current = "" }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.joined(separator: separator)
    }

    /// Truncate a `_`-joined slug to ≤ 24 characters at a `_` boundary where
    /// possible (§16.5 step 6). Falls back to a hard character cut otherwise.
    private func truncateShortTitle(_ slug: String) -> String {
        truncateAtBoundary(slug, to: Self.librivoxShortTitleLimit)
    }

    /// Truncate at a `_` boundary at or before `limit`; hard-cuts otherwise.
    private func truncateAtBoundary(_ slug: String, to limit: Int) -> String {
        guard slug.count > limit else { return slug }
        var cut = limit
        while cut > 0 {
            let index = slug.index(slug.startIndex, offsetBy: cut)
            if slug[slug.index(before: index)] == "_" {
                return String(slug[..<slug.index(before: index)])
            }
            cut -= 1
        }
        return String(slug.prefix(limit))
    }

    /// Decompose and strip combining marks; map `ß` explicitly (no combining
    /// decomposition exists for it). Lowercasing is the caller's job.
    private func stripDiacritics(_ raw: String) -> String {
        let mapped = raw
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
        return mapped.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Zero-padded section number, minimum width 2, growing with the section
    /// count (§16.5: `digits(sectionCount)`, floor 2).
    private func zeroPadded(_ section: Int, sectionCount: Int) -> String {
        let width = max(2, String(sectionCount).count)
        return String(format: "%0\(width)d", section)
    }
}
