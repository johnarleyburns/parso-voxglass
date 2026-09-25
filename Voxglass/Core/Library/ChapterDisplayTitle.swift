import Foundation

/// Presentation-ready chapter eyebrow and title.
public struct ChapterDisplayTitle: Equatable, Sendable {
    public var eyebrow: String?
    public var title: String

    public init(eyebrow: String?, title: String) {
        self.eyebrow = eyebrow
        self.title = title
    }
}

/// Parses common LibriVox chapter-title prefixes without changing stored chapters.
public enum ChapterDisplayTitles {
    public static func make(for chapters: [Chapter]) -> [UUID: ChapterDisplayTitle] {
        var result: [UUID: ChapterDisplayTitle] = [:]
        let parsed = chapters.map(parse)
        for index in chapters.indices {
            let item = parsed[index]
            guard item.name != chapters[index].title || item.part != nil || item.chapter != nil else {
                result[chapters[index].id] = ChapterDisplayTitle(eyebrow: nil, title: chapters[index].title)
                continue
            }
            let group = parsed.indices.filter { parsed[$0].part == item.part && parsed[$0].chapter == item.chapter && parsed[$0].name == item.name }
            let position = (group.firstIndex(of: index) ?? 0) + 1
            var pieces: [String] = []
            if let part = item.part { pieces.append("Part \(part)") }
            if let chapter = item.chapter { pieces.append("Ch. \(chapter)") }
            if let section = item.section {
                pieces.append(group.count > 1 ? "\(section) of \(group.count)" : "Section \(section)")
            }
            else if group.count > 1 { pieces.append("\(position) of \(group.count)") }
            result[chapters[index].id] = ChapterDisplayTitle(
                eyebrow: pieces.isEmpty ? nil : pieces.joined(separator: " · "),
                title: item.name
            )
        }
        return result
    }

    private struct Parsed { let part: String?; let chapter: String?; let section: String?; let name: String }

    private static func parse(_ chapter: Chapter) -> Parsed { parse(chapter.title) }

    private static func parse(_ original: String) -> Parsed {
        var value = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"^\d+\s*[-–.:]\s*"#, options: .regularExpression) { value.removeSubrange(range) }
        let part = capture(#"(?i)\b(?:Pt\.?|Part|Book|Bk\.?)\s*([0-9]+|[IVXLCDM]+)"#, value).map(normalizeNumber)
        let chapter = capture(#"(?i)\b(?:Ch\.?|Chapter|Chap\.?)\s*([0-9]+|[IVXLCDM]+)"#, value).map(normalizeNumber)
        let section = capture(#"(?i)\(\s*(?:Section|Sec\.?|Part|Pt\.?)\s+([0-9]+)\s*\)"#, value).map(normalizeNumber)
        value = value.replacingOccurrences(of: #"(?i)\b(?:Pt\.?|Part|Book|Bk\.?)\s*(?:[0-9]+|[IVXLCDM]+)\s*,?\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b(?:Ch\.?|Chapter|Chap\.?)\s*(?:[0-9]+|[IVXLCDM]+)\s*:?\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\(\s*(?:Section|Sec\.?|Part|Pt\.?)\s+[0-9]+\s*\)"#, with: "", options: .regularExpression)
        return Parsed(part: part, chapter: chapter, section: section, name: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func normalizeNumber(_ value: String) -> String {
        if let number = Int(value) { return String(number) }
        let roman = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0; var previous = 0
        for char in value.uppercased().reversed() {
            let current = roman[String(char)] ?? 0
            total += current < previous ? -current : current
            previous = current
        }
        return total > 0 ? String(total) : value
    }
}
