import Foundation

struct NarratorMatcher {

    static func match(
        chapters: [Chapter],
        sections: [LibriVoxSection],
        archiveIdentifier: String
    ) -> [UUID: [String]] {
        guard !chapters.isEmpty, !sections.isEmpty else { return [:] }

        var chapterNarrators: [UUID: [String]] = [:]

        if let result = tryStemJoin(chapters: chapters, sections: sections, archiveIdentifier: archiveIdentifier) {
            return result
        }

        if let result = tryPositional(chapters: chapters, sections: sections, archiveIdentifier: archiveIdentifier) {
            return result
        }

        return bookLevelOnly(sections: sections)
    }

    static func bookLevelNarrators(from sections: [LibriVoxSection]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for section in sections {
            for reader in section.readers {
                let name = reader.displayNameOrUnknown
                if seen.insert(name).inserted {
                    ordered.append(name)
                }
            }
        }
        return ordered
    }

    private static func tryStemJoin(
        chapters: [Chapter],
        sections: [LibriVoxSection],
        archiveIdentifier: String
    ) -> [UUID: [String]]? {
        let validatedSections = sections.filter { sectionMatchesArchive(section: $0, identifier: archiveIdentifier) }
        guard !validatedSections.isEmpty else { return nil }

        let sectionByStem: [String: LibriVoxSection] = {
            var dict: [String: LibriVoxSection] = [:]
            for section in validatedSections {
                let stem = sectionStem(section)
                guard !stem.isEmpty else { continue }
                if dict[stem] == nil {
                    dict[stem] = section
                }
            }
            return dict
        }()
        guard !sectionByStem.isEmpty else { return nil }

        var result: [UUID: [String]] = [:]
        var matchedCount = 0
        for chapter in chapters {
            guard let url = chapter.remoteURL else { continue }
            let chapterStem = urlStem(url)
            guard !chapterStem.isEmpty else { continue }
            if let section = sectionByStem[chapterStem] {
                let names = section.readers.map(\.displayNameOrUnknown)
                result[chapter.id] = names
                matchedCount += 1
            }
        }
        return matchedCount > 0 ? result : nil
    }

    private static func tryPositional(
        chapters: [Chapter],
        sections: [LibriVoxSection],
        archiveIdentifier: String
    ) -> [UUID: [String]]? {
        let validated = sections.filter { sectionMatchesArchive(section: $0, identifier: archiveIdentifier) }
        guard validated.count == chapters.count else { return nil }

        let ordered = validated.sorted { lhs, rhs in
            let ln = Int(lhs.sectionNumber ?? "") ?? 0
            let rn = Int(rhs.sectionNumber ?? "") ?? 0
            if ln != rn { return ln < rn }
            return (lhs.sectionNumber ?? "") < (rhs.sectionNumber ?? "")
        }

        var result: [UUID: [String]] = [:]
        for (index, chapter) in chapters.enumerated() {
            guard index < ordered.count else { break }
            result[chapter.id] = ordered[index].readers.map(\.displayNameOrUnknown)
        }
        return result
    }

    private static func bookLevelOnly(sections: [LibriVoxSection]) -> [UUID: [String]] {
        [:]
    }

    static func sectionMatchesArchive(section: LibriVoxSection, identifier: String) -> Bool {
        guard let urlIArchive = section.urlIArchive else { return false }
        let stripped = urlIArchive
            .replacingOccurrences(of: "https://archive.org/details/", with: "")
            .replacingOccurrences(of: "http://archive.org/details/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return stripped == identifier
    }

    static func sectionStem(_ section: LibriVoxSection) -> String {
        let raw: String
        if let fn = section.fileName, !fn.isEmpty {
            raw = fn
        } else if let url = section.listenURL.flatMap(URL.init(string:)) {
            raw = url.lastPathComponent
        } else {
            return ""
        }
        return normalizeStem(raw)
    }

    static func urlStem(_ url: URL) -> String {
        normalizeStem(url.lastPathComponent)
    }

    private static func normalizeStem(_ value: String) -> String {
        var stem = value
            .replacingOccurrences(of: "_64kb", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_128kb", with: "", options: .caseInsensitive)
        if let dot = stem.lastIndex(of: ".") {
            stem = String(stem[..<dot])
        }
        stem = stem.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
            .lowercased()
        return stem
    }
}
