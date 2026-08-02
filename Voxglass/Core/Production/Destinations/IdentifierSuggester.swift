import Foundation

/// Internet Archive item-identifier suggestion and validation (§3.3.1, §16.5).
///
/// An archive.org identifier is globally unique, immutable after creation, and
/// constrained to ASCII alphanumerics plus `- _ .`, conventionally lowercase,
/// 5–80 characters. Voxglass only *suggests* one; the user must confirm
/// availability on the archive before uploading. The UI states: *"Identifiers
/// are permanent and must be unique on archive.org. Confirm availability
/// before uploading."*
public struct IdentifierSuggester: Sendable {

    /// Maximum length of a suggested identifier.
    public static let suggestedLengthLimit = 60

    public init() {}

    /// `<titleslug>_<authorlastname>_<narratorlastname>`, lowercased,
    /// `_`-joined, truncated at 60 characters with no trailing separator
    /// (§16.5). Always valid per `isValid` when any slug is non-empty; falls
    /// back to a date-stamped identifier when everything is empty.
    public func suggest(title: String, author: String, narrator: String, year: Int?) -> String {
        let titleSlug = slug(title)
        let authorSlug = lastNameSlug(author)
        let narratorSlug = lastNameSlug(narrator)

        let base = [titleSlug, authorSlug, narratorSlug].filter { !$0.isEmpty }
        var candidate: String
        if base.isEmpty {
            let stamp = String(year ?? 0)
            candidate = "audiobook" + (stamp.isEmpty ? "" : "_\(stamp)")
            if !isValid(candidate) { candidate = "audiobook" }
        } else {
            candidate = base.joined(separator: "_")
        }

        if candidate.count > Self.suggestedLengthLimit {
            // Truncate at a `_` boundary so the trailing separator never leaks.
            var cut = Self.suggestedLengthLimit
            while cut > 0 {
                let index = candidate.index(candidate.startIndex, offsetBy: cut)
                if candidate[candidate.index(before: index)] == "_" {
                    candidate = String(candidate[..<candidate.index(before: index)])
                    break
                }
                cut -= 1
            }
            if cut == 0 { candidate = String(candidate.prefix(Self.suggestedLengthLimit)) }
        }
        return candidate
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{4,79}$` (§3.3.1 constraints: ASCII
    /// alphanumeric start, 5–80 characters, `- _ .` allowed after the first).
    public func isValid(_ id: String) -> Bool {
        let pattern = "^[A-Za-z0-9][A-Za-z0-9._\\-]{4,79}$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Private

    private func slug(_ raw: String) -> String {
        let deaccented = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let lower = deaccented.lowercased()
        var pieces: [String] = []
        var current = ""
        for scalar in lower.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { pieces.append(current); current = "" }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.joined(separator: "_")
    }

    /// The surname = the final whitespace-delimited word, de-accented and slugged.
    private func lastNameSlug(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: \.isWhitespace).last else { return "" }
        return slug(String(last))
    }
}
