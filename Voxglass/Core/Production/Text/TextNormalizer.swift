import Foundation

public enum TextNormalizer {
    public static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
         .replacingOccurrences(of: "\u{00A0}", with: " ")
         .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
         .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
         .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
         .replacingOccurrences(of: "\u{2026}", with: "...")
         .components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func identityKey(_ s: String) -> String {
        let normalized = normalize(s)
        let lowercased = normalized.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.whitespaces)
        let stripped = lowercased.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
        return stripped.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func hash(_ s: String) -> String {
        SHA256Hex.hex(Data(normalize(s).utf8))
    }
}
