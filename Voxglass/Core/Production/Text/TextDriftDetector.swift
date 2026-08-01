import Foundation

public enum DriftKind: String, Sendable, Codable, CaseIterable {
    case none
    case cosmetic
    case minor
    case semantic
}

public struct TextDriftDetector: Sendable {
    public init() {}

    public func classify(recorded: String, current: String) -> DriftKind {
        if TextNormalizer.hash(recorded) == TextNormalizer.hash(current) {
            return .none
        }

        let recTokens = tokenize(recorded)
        let curTokens = tokenize(current)

        // §9.5 step 4, run before the cosmetic/minor checks: if the only
        // difference is a number word or digit, it is always .semantic.
        let recNonNumber = recTokens.filter { !Self.isNumberToken($0) }
        let curNonNumber = curTokens.filter { !Self.isNumberToken($0) }
        if recNonNumber == curNonNumber && recTokens != curTokens {
            return .semantic
        }

        if TextNormalizer.identityKey(recorded) == TextNormalizer.identityKey(current) {
            return .cosmetic
        }

        let d = levenshteinDistance(recTokens, curTokens)
        let n = max(recTokens.count, curTokens.count)
        guard n > 0 else { return .semantic }

        if d <= 2 && Double(d) / Double(n) <= 0.05 {
            return .minor
        }

        return .semantic
    }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "twentieth",
    ]

    private static func isNumberToken(_ token: String) -> Bool {
        if token.allSatisfy({ $0.isNumber }) && !token.isEmpty { return true }
        return numberWords.contains(token)
    }

    private func tokenize(_ s: String) -> [String] {
        TextNormalizer.identityKey(s).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private func levenshteinDistance(_ a: [String], _ b: [String]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
