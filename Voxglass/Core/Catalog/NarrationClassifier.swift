import Foundation

public enum NarrationClassifier {

    private static let blockedCollectives: Set<String> = [
        "volunteers", "cast", "full cast",
        "various", "group", "dramatic reading", "collaborative",
        "unknown", "anonymous", "librivox volunteers",
        "multiple readers", "multiple narrators", "several readers",
        "many readers", "a full cast", "a cast"
    ]

    public static func classify(narrators: [String]) -> NarrationKind {
        let cleaned = narrators
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return .mixedOrUnknown }

        if cleaned.count > 1 { return .mixedOrUnknown }

        let name = cleaned[0]
        let lowered = name.lowercased()

        if blockedCollectives.contains(lowered) { return .mixedOrUnknown }

        if lowered.contains("volunteer")
            || lowered.contains("cast")
            || lowered.contains("dramatic")
            || lowered.contains("collaborative")
            || lowered.contains("various")
            || lowered.contains("unknown")
            || lowered.contains("anonymous")
            || lowered.contains("readers")
            || lowered.contains("narrators")
            || lowered.contains("group") {
            return .mixedOrUnknown
        }

        guard name.rangeOfCharacter(from: .letters) != nil else { return .mixedOrUnknown }

        let nameWithoutLabels = stripLeadingLabels(name)
        let parts = nameWithoutLabels
            .components(separatedBy: CharacterSet(charactersIn: ",&/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isPlausiblePersonName($0) }

        if parts.count != 1 { return .mixedOrUnknown }

        return .solo
    }

    public static func classify(description: String?) -> NarrationKind {
        let names = NarratorExtractor.extract(from: description)
        return classify(narrators: names)
    }

    public static func classify(chapterNarrators: [String], bookNarrators: [String]) -> NarrationKind {
        let allNarrators = Set(chapterNarrators.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let bookSet = Set(bookNarrators.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })

        if allNarrators.isEmpty { return classify(narrators: bookNarrators) }

        if allNarrators.count > 1 { return .mixedOrUnknown }

        let name = allNarrators.first!
        let lowered = name.lowercased()

        if blockedCollectives.contains(lowered) { return .mixedOrUnknown }

        if lowered.contains("volunteer")
            || lowered.contains("cast")
            || lowered.contains("dramatic")
            || lowered.contains("collaborative")
            || lowered.contains("various")
            || lowered.contains("unknown")
            || lowered.contains("anonymous")
            || lowered.contains("readers")
            || lowered.contains("narrators")
            || lowered.contains("group") {
            return .mixedOrUnknown
        }

        guard isPlausiblePersonName(name) else { return .mixedOrUnknown }

        return .solo
    }

    private static func stripLeadingLabels(_ name: String) -> String {
        let labels = [
            "read by ", "narrated by ", "reader: ", "narrator: ",
            "performed by ", "voiced by ", "read by:", "narrated by:",
            "reader:", "narrator:", "performed by:", "voiced by:"
        ]
        let lowered = name.lowercased()
        for label in labels {
            if lowered.hasPrefix(label) {
                let start = name.index(name.startIndex, offsetBy: label.count)
                return String(name[start...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return name
    }

    private static func isPlausiblePersonName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard trimmed.count >= 2, trimmed.count <= 80 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        let lowered = trimmed.lowercased()
        if blockedCollectives.contains(lowered) { return false }
        if lowered.contains("volunteer") || lowered.contains("cast") || lowered.contains("dramatic")
            || lowered.contains("various") || lowered.contains("unknown") || lowered.contains("anonymous")
            || lowered.contains("group") || lowered.contains("readers") || lowered.contains("narrators") {
            return false
        }
        return true
    }
}
