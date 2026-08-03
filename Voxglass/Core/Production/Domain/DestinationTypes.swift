import Foundation

// MARK: - Destination ID

public enum DestinationID: String, Codable, Sendable, CaseIterable {
    case librivox, internetArchive, acx, appleBooksAggregator, personalMaster
}

// MARK: - Tier

public enum Tier: String, Codable, Sendable { case free, pro }

// MARK: - File Granularity

public enum FileGranularity: String, Codable, Sendable { case perChapter, wholeBookChapterized, perParagraph }

// MARK: - Container

public enum Container: String, Codable, Sendable { case mp3, wav, flac, m4a, m4b, caf }

// MARK: - Codec

public enum Codec: String, Codable, Sendable { case mp3, pcm, flac, aacLC, alac }

// MARK: - AudioSpec

public struct AudioSpec: Codable, Sendable, Equatable {
    public let container: Container
    public let codec: Codec
    public let sampleRate: Double?
    public let channels: Int?
    public let bitrateKbps: Int?
    public let isCBR: Bool
    public let bitDepth: Int?

    public init(
        container: Container,
        codec: Codec,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        bitrateKbps: Int? = nil,
        isCBR: Bool = false,
        bitDepth: Int? = nil
    ) {
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrateKbps = bitrateKbps
        self.isCBR = isCBR
        self.bitDepth = bitDepth
    }
}

// MARK: - FilenameRule

public enum FilenameRule: String, Codable, Sendable {
    case librivoxLowercaseNoSpace
    case archiveIdentifierPrefixed
    case freeformNumbered
}

// MARK: - LoudnessRule

public enum LoudnessRule: Codable, Sendable, Equatable {
    case rmsWindow(minDBFS: Double, maxDBFS: Double, targetDBFS: Double)
    case replayGainBand(low: Double, high: Double, target: Double)

    private enum CodingKeys: String, CodingKey { case kind, minDBFS, maxDBFS, targetDBFS, low, high, target }
    private enum Kind: String, Codable { case rmsWindow, replayGainBand }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .rmsWindow:
            self = .rmsWindow(
                minDBFS: try c.decode(Double.self, forKey: .minDBFS),
                maxDBFS: try c.decode(Double.self, forKey: .maxDBFS),
                targetDBFS: try c.decode(Double.self, forKey: .targetDBFS)
            )
        case .replayGainBand:
            self = .replayGainBand(
                low: try c.decode(Double.self, forKey: .low),
                high: try c.decode(Double.self, forKey: .high),
                target: try c.decode(Double.self, forKey: .target)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rmsWindow(let minDBFS, let maxDBFS, let targetDBFS):
            try c.encode(Kind.rmsWindow, forKey: .kind)
            try c.encode(minDBFS, forKey: .minDBFS)
            try c.encode(maxDBFS, forKey: .maxDBFS)
            try c.encode(targetDBFS, forKey: .targetDBFS)
        case .replayGainBand(let low, let high, let target):
            try c.encode(Kind.replayGainBand, forKey: .kind)
            try c.encode(low, forKey: .low)
            try c.encode(high, forKey: .high)
            try c.encode(target, forKey: .target)
        }
    }
}

// MARK: - SilenceRule

public struct SilenceRule: Codable, Sendable, Equatable {
    public let headMin: TimeInterval
    public let headMax: TimeInterval
    public let tailMin: TimeInterval
    public let tailMax: TimeInterval

    public init(headMin: TimeInterval, headMax: TimeInterval, tailMin: TimeInterval, tailMax: TimeInterval) {
        self.headMin = headMin
        self.headMax = headMax
        self.tailMin = tailMin
        self.tailMax = tailMax
    }
}

// MARK: - RetailSampleRule

public struct RetailSampleRule: Codable, Sendable, Equatable {
    public let minDuration: TimeInterval
    public let maxDuration: TimeInterval
    public let mustStartWithNarration: Bool

    public init(minDuration: TimeInterval, maxDuration: TimeInterval, mustStartWithNarration: Bool) {
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.mustStartWithNarration = mustStartWithNarration
    }
}

// MARK: - ArtworkRule

public enum ArtworkRule: Codable, Sendable, Equatable {
    case none
    case optionalSquare(minPx: Int)
    case requiredSquare(minPx: Int, colorSpace: ColorSpaceRule, format: ImageFormat)

    private enum CodingKeys: String, CodingKey { case kind, minPx, colorSpace, format }
    private enum Kind: String, Codable { case none, optionalSquare, requiredSquare }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .optionalSquare:
            self = .optionalSquare(minPx: try c.decode(Int.self, forKey: .minPx))
        case .requiredSquare:
            self = .requiredSquare(
                minPx: try c.decode(Int.self, forKey: .minPx),
                colorSpace: try c.decode(ColorSpaceRule.self, forKey: .colorSpace),
                format: try c.decode(ImageFormat.self, forKey: .format)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(Kind.none, forKey: .kind)
        case .optionalSquare(let minPx):
            try c.encode(Kind.optionalSquare, forKey: .kind)
            try c.encode(minPx, forKey: .minPx)
        case .requiredSquare(let minPx, let colorSpace, let format):
            try c.encode(Kind.requiredSquare, forKey: .kind)
            try c.encode(minPx, forKey: .minPx)
            try c.encode(colorSpace, forKey: .colorSpace)
            try c.encode(format, forKey: .format)
        }
    }
}

public enum ColorSpaceRule: String, Codable, Sendable { case rgb }
public enum ImageFormat: String, Codable, Sendable { case jpeg, png }

// MARK: - MetadataField

public enum MetadataField: String, Codable, Sendable, CaseIterable {
    case title, subtitle, author, narrator, language, description, subjects,
         sourceURL, rightsBasis, rightsAttestation, cover, publisher,
         copyrightYear, productionYear, identifier, licenseURL, date, isbn
}

// MARK: - DestinationProfile

public struct DestinationProfile: Codable, Sendable, Equatable {
    public let id: DestinationID
    public let displayName: String
    public let tier: Tier
    public let audio: AudioSpec
    public let secondaryAudio: AudioSpec?
    public let fileGranularity: FileGranularity
    public let maxFileDuration: TimeInterval?
    public let filenameRule: FilenameRule
    public let requiredMetadata: [MetadataField]
    public let requiresHumanNarration: Bool
    public let requiresScriptedDisclaimer: Bool
    public let requiresCredits: Bool
    public let loudness: LoudnessRule?
    public let peakCeilingDBFS: Double?
    public let noiseFloorCeilingDBFS: Double?
    public let headroomSilence: SilenceRule?
    public let retailSample: RetailSampleRule?
    public let artwork: ArtworkRule
    public let emitsChecksums: Bool
    public let autoUpload: Bool

    public init(
        id: DestinationID,
        displayName: String,
        tier: Tier,
        audio: AudioSpec,
        secondaryAudio: AudioSpec? = nil,
        fileGranularity: FileGranularity,
        maxFileDuration: TimeInterval? = nil,
        filenameRule: FilenameRule,
        requiredMetadata: [MetadataField],
        requiresHumanNarration: Bool,
        requiresScriptedDisclaimer: Bool,
        requiresCredits: Bool = false,
        loudness: LoudnessRule? = nil,
        peakCeilingDBFS: Double? = nil,
        noiseFloorCeilingDBFS: Double? = nil,
        headroomSilence: SilenceRule? = nil,
        retailSample: RetailSampleRule? = nil,
        artwork: ArtworkRule,
        emitsChecksums: Bool,
        autoUpload: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.audio = audio
        self.secondaryAudio = secondaryAudio
        self.fileGranularity = fileGranularity
        self.maxFileDuration = maxFileDuration
        self.filenameRule = filenameRule
        self.requiredMetadata = requiredMetadata
        self.requiresHumanNarration = requiresHumanNarration
        self.requiresScriptedDisclaimer = requiresScriptedDisclaimer
        self.requiresCredits = requiresCredits
        self.loudness = loudness
        self.peakCeilingDBFS = peakCeilingDBFS
        self.noiseFloorCeilingDBFS = noiseFloorCeilingDBFS
        self.headroomSilence = headroomSilence
        self.retailSample = retailSample
        self.artwork = artwork
        self.emitsChecksums = emitsChecksums
        self.autoUpload = autoUpload
    }
}

// The standard profile *literals* live in
// `Destinations/DestinationProfiles.swift`; this file holds only the type.
