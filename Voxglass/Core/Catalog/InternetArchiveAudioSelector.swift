import Foundation

enum InternetArchiveAudioSelector {
    static let playableAudioExtensions = Set(["aac", "aif", "aiff", "caf", "m4a", "m4b", "mp3", "wav"])

    static func selectedAudioFiles(from files: [InternetArchiveFile]) -> [InternetArchiveFile] {
        let candidates = files.filter(isPlayableAudio)
        var bestByChapter: [String: InternetArchiveFile] = [:]

        for file in candidates {
            let key = canonicalChapterKey(for: file)
            if let current = bestByChapter[key] {
                if qualityScore(for: file) > qualityScore(for: current) {
                    bestByChapter[key] = file
                }
            } else {
                bestByChapter[key] = file
            }
        }

        return bestByChapter.values.sorted(by: audioOrder)
    }

    static func isPlayableAudio(_ file: InternetArchiveFile) -> Bool {
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        guard playableAudioExtensions.contains(ext) else { return false }

        let format = file.format?.lowercased() ?? ""
        if format.contains("metadata") || format.contains("spectrogram") {
            return false
        }
        if file.name.lowercased().hasSuffix(".m3u") {
            return false
        }
        return true
    }

    static func chapterTitle(for file: InternetArchiveFile) -> String {
        if let title = file.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title.cleanedInternetArchiveText
        }

        let baseName = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
        let withoutDerivativeSuffix = baseName.replacingOccurrences(
            of: #"(?i)(?:[_\-\s]?(?:64kb|128kb|160kb|192kb|256kb|vbr|vbr_mp3))+$"#,
            with: "",
            options: .regularExpression
        )
        let normalized = withoutDerivativeSuffix
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? baseName : normalized
    }

    private static func canonicalChapterKey(for file: InternetArchiveFile) -> String {
        chapterTitle(for: file)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func qualityScore(for file: InternetArchiveFile) -> Int {
        let sourceScore = file.source?.localizedCaseInsensitiveCompare("original") == .orderedSame ? 10_000 : 0
        let format = file.format?.lowercased() ?? ""
        let name = file.name.lowercased()
        let extensionScore: Int

        if name.hasSuffix(".m4b") {
            extensionScore = 700
        } else if name.hasSuffix(".m4a") || name.hasSuffix(".aac") {
            extensionScore = 650
        } else if name.hasSuffix(".mp3") {
            extensionScore = 600
        } else {
            extensionScore = 300
        }

        let formatScore: Int
        if format.contains("256") {
            formatScore = 560
        } else if format.contains("192") {
            formatScore = 520
        } else if format.contains("vbr") {
            formatScore = 500
        } else if format.contains("160") {
            formatScore = 460
        } else if format.contains("128") {
            formatScore = 420
        } else if format.contains("64") {
            formatScore = 260
        } else {
            formatScore = 320
        }

        return sourceScore + extensionScore + formatScore
    }

    private static func audioOrder(_ lhs: InternetArchiveFile, _ rhs: InternetArchiveFile) -> Bool {
        let lhsOrdinal = chapterOrdinal(for: lhs)
        let rhsOrdinal = chapterOrdinal(for: rhs)
        if let lhsOrdinal, let rhsOrdinal, lhsOrdinal != rhsOrdinal {
            return lhsOrdinal < rhsOrdinal
        }
        if lhsOrdinal != nil, rhsOrdinal == nil {
            return true
        }
        if lhsOrdinal == nil, rhsOrdinal != nil {
            return false
        }
        return chapterTitle(for: lhs).localizedStandardCompare(chapterTitle(for: rhs)) == .orderedAscending
    }

    private static func chapterOrdinal(for file: InternetArchiveFile) -> Int? {
        if let track = file.track, let trackNumber = firstNumber(in: track) {
            return trackNumber
        }
        if let title = file.title, let titleNumber = firstNumber(in: title) {
            return titleNumber
        }
        return firstNumber(in: file.name)
    }

    private static func firstNumber(in value: String) -> Int? {
        var digits = ""
        var didStart = false

        for scalar in value.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.append(String(scalar))
                didStart = true
            } else if didStart {
                break
            }
        }

        return digits.isEmpty ? nil : Int(digits)
    }
}
