import Foundation

enum InternetArchiveAudioSelector {
    static let playableAudioExtensions = AudioFormatSelection.allPlayableExtensions

    static func selectedAudioFiles(
        from files: [InternetArchiveFile],
        policy: DerivativePolicy? = nil
    ) -> [InternetArchiveFile] {
        let candidates = files.filter(isPlayableAudio)
        guard !candidates.isEmpty else { return [] }

        // Determine the single codec family to use for this item.
        // Without a policy, fall back to picking the highest-ranked codec
        // that has at least one candidate file (Wi-Fi default).
        let chosenCodec: AudioCodec?
        if let policy {
            chosenCodec = policy.bestCodec(for: candidates)?.codec
        } else {
            chosenCodec = bestAvailableCodec(from: candidates)
        }

        // Filter to the chosen codec family, keeping legacy formats
        // (WAV, AAC, M4A, etc.) that don't map to any codec.
        let familyFiles: [InternetArchiveFile]
        if let chosenCodec {
            familyFiles = candidates.filter { file in
                AudioFormatSelection.codec(for: file.format, filename: file.name) == chosenCodec
            }
        } else {
            familyFiles = candidates
        }

        // If the chosen codec has no files, fall back to all candidates.
        let pool = familyFiles.isEmpty ? candidates : familyFiles

        var bestByChapter: [String: InternetArchiveFile] = [:]

        for file in pool {
            let key = canonicalChapterKey(for: file)
            if let current = bestByChapter[key] {
                let currentCodec = AudioFormatSelection.codec(for: current.format, filename: current.name) ?? .mp3
                let fileCodec = AudioFormatSelection.codec(for: file.format, filename: file.name) ?? .mp3
                if AudioFormatSelection.qualityRank(for: file, codec: fileCodec)
                    > AudioFormatSelection.qualityRank(for: current, codec: currentCodec) {
                    bestByChapter[key] = file
                }
            } else {
                bestByChapter[key] = file
            }
        }

        return bestByChapter.values.sorted(by: audioOrder)
    }

    private static func bestAvailableCodec(from files: [InternetArchiveFile]) -> AudioCodec? {
        for codec in AudioCodec.allCases.sorted(by: >) {
            if files.contains(where: { AudioFormatSelection.codec(for: $0.format, filename: $0.name) == codec }) {
                return codec
            }
        }
        return nil
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
        let codec = AudioFormatSelection.codec(for: file.format, filename: file.name) ?? .mp3
        return AudioFormatSelection.qualityRank(for: file, codec: codec)
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
