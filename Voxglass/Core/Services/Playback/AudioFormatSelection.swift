import Foundation

enum AudioCodec: Int, Comparable, CaseIterable {
    case flac = 3
    case opus = 2
    case vorbis = 1
    case mp3 = 0

    static func < (lhs: AudioCodec, rhs: AudioCodec) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .flac: return "FLAC"
        case .opus: return "Opus"
        case .vorbis: return "Vorbis"
        case .mp3: return "MP3"
        }
    }
}

struct AudioFormatSelection {
    private static let acceptedFormats: [AudioCodec: Set<String>] = [
        .flac: ["Flac", "24bit Flac"],
        .opus: ["Opus"],
        .vorbis: ["Ogg Vorbis", "Vorbis"],
        .mp3: [
            "VBR MP3", "128Kbps MP3", "64Kbps MP3", "256Kbps MP3",
            "320Kbps MP3", "192Kbps MP3", "MP3", "MPEG Audio Layer 3"
        ]
    ]

    private static let acceptedExtensions: [AudioCodec: Set<String>] = [
        .flac: ["flac"],
        .opus: ["opus"],
        .vorbis: ["ogg"],
        .mp3: ["mp3"]
    ]

    static let allPlayableExtensions: Set<String> = {
        var all = Set<String>()
        for (_, exts) in acceptedExtensions { all.formUnion(exts) }
        // Also keep the existing extensions that don't map to our codecs
        all.formUnion(["aac", "aif", "aiff", "caf", "m4a", "m4b", "wav"])
        return all
    }()

    static func codec(for format: String?, filename: String) -> AudioCodec? {
        let ext = (filename as NSString).pathExtension.lowercased()

        for codec in AudioCodec.allCases.sorted(by: >) {
            if let exts = acceptedExtensions[codec], exts.contains(ext) {
                return codec
            }
        }

        if let format {
            let lower = format.lowercased()
            for codec in AudioCodec.allCases.sorted(by: >) {
                if let formats = acceptedFormats[codec] {
                    for accepted in formats {
                        if lower == accepted.lowercased() || lower.contains(accepted.lowercased()) {
                            return codec
                        }
                    }
                }
            }
            // Heuristic fallback
            if lower.contains("flac") { return .flac }
            if lower.contains("opus") { return .opus }
            if lower.contains("vorbis") || lower.contains("ogg") { return .vorbis }
            if lower.contains("mp3") { return .mp3 }
        }

        return nil
    }

    static func isValidFormat(_ format: String?, filename: String) -> Bool {
        codec(for: format, filename: filename) != nil
    }

    static func qualityRank(for file: InternetArchiveFile, codec: AudioCodec) -> Int {
        let baseCodecRank = codec.rawValue * 1000

        let format = file.format?.lowercased() ?? ""
        let bitrateScore: Int
        if format.contains("320") { bitrateScore = 600 }
        else if format.contains("256") { bitrateScore = 500 }
        else if format.contains("192") { bitrateScore = 400 }
        else if format.contains("vbr") { bitrateScore = 350 }
        else if format.contains("128") { bitrateScore = 200 }
        else if format.contains("64") { bitrateScore = 100 }
        else { bitrateScore = 300 }

        let sourceScore = file.source?.localizedCaseInsensitiveCompare("original") == .orderedSame ? 500 : 0

        return baseCodecRank + sourceScore + bitrateScore
    }
}

struct DerivativePolicy {
    enum NetworkCondition {
        case wifi
        case cellular
        case offline
    }

    let networkCondition: NetworkCondition
    let isPrefetchOrQueued: Bool
    let hasCachedOpusCAF: Bool
    let preferLosslessOnCellular: Bool

    init(
        networkCondition: NetworkCondition = .wifi,
        isPrefetchOrQueued: Bool = false,
        hasCachedOpusCAF: Bool = false,
        preferLosslessOnCellular: Bool = false
    ) {
        self.networkCondition = networkCondition
        self.isPrefetchOrQueued = isPrefetchOrQueued
        self.hasCachedOpusCAF = hasCachedOpusCAF
        self.preferLosslessOnCellular = preferLosslessOnCellular
    }

    var rankedCodecs: [AudioCodec] {
        if hasCachedOpusCAF {
            return [.opus]
        }

        if isPrefetchOrQueued {
            return [.opus, .flac, .mp3]
        }

        switch networkCondition {
        case .wifi:
            return [.flac, .mp3]
        case .cellular:
            if preferLosslessOnCellular {
                return [.flac, .mp3]
            }
            return [.mp3]
        case .offline:
            return [.mp3]
        }
    }

    func bestCodec(for files: [InternetArchiveFile]) -> (codec: AudioCodec, file: InternetArchiveFile)? {
        for codec in rankedCodecs {
            let candidates = files.filter { AudioFormatSelection.codec(for: $0.format, filename: $0.name) == codec }
            if let best = candidates.max(by: { a, b in
                AudioFormatSelection.qualityRank(for: a, codec: codec) < AudioFormatSelection.qualityRank(for: b, codec: codec)
            }) {
                return (codec, best)
            }
        }
        return nil
    }
}
