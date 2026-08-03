import Foundation

// MARK: - AudioOrigin

public enum AudioOrigin: Sendable, Equatable, Hashable {
    case recorded
    case importedHuman(sourceFilename: String)
    case aiImported(providerLabel: String)
    case unknownImport(sourceFilename: String)

    public var isHumanNarration: Bool {
        switch self {
        case .recorded, .importedHuman: return true
        case .aiImported, .unknownImport: return false
        }
    }

    public var storageKind: String {
        switch self {
        case .recorded: return "recorded"
        case .importedHuman: return "importedHuman"
        case .aiImported: return "aiImported"
        case .unknownImport: return "unknownImport"
        }
    }

    public var storagePayload: String? {
        switch self {
        case .recorded: return nil
        case .importedHuman(let f): return f
        case .aiImported(let p): return p
        case .unknownImport(let f): return f
        }
    }

    public init(storageKind: String, storagePayload: String?) throws {
        switch storageKind {
        case "recorded":
            self = .recorded
        case "importedHuman":
            guard let payload = storagePayload else {
                throw AudioOriginDecodingError.missingPayload
            }
            self = .importedHuman(sourceFilename: payload)
        case "aiImported":
            guard let payload = storagePayload else {
                throw AudioOriginDecodingError.missingPayload
            }
            self = .aiImported(providerLabel: payload)
        case "unknownImport":
            guard let payload = storagePayload else {
                throw AudioOriginDecodingError.missingPayload
            }
            self = .unknownImport(sourceFilename: payload)
        default:
            throw AudioOriginDecodingError.unknownKind(storageKind)
        }
    }

    public enum AudioOriginDecodingError: Error {
        case missingPayload
        case unknownKind(String)
    }
}

extension AudioOrigin: Codable {
    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum Kind: String, Codable { case recorded, importedHuman, aiImported, unknownImport }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .recorded:
            self = .recorded
        case .importedHuman:
            self = .importedHuman(sourceFilename: try c.decode(String.self, forKey: .payload))
        case .aiImported:
            self = .aiImported(providerLabel: try c.decode(String.self, forKey: .payload))
        case .unknownImport:
            self = .unknownImport(sourceFilename: try c.decode(String.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recorded:
            try c.encode(Kind.recorded, forKey: .kind)
        case .importedHuman(let f):
            try c.encode(Kind.importedHuman, forKey: .kind); try c.encode(f, forKey: .payload)
        case .aiImported(let p):
            try c.encode(Kind.aiImported, forKey: .kind); try c.encode(p, forKey: .payload)
        case .unknownImport(let f):
            try c.encode(Kind.unknownImport, forKey: .kind); try c.encode(f, forKey: .payload)
        }
    }
}

// MARK: - AudioFormatDescription

public struct AudioFormatDescription: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var bitDepth: Int?
    public var codec: String

    public init(sampleRate: Double, channels: Int, bitDepth: Int? = nil, codec: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.codec = codec
    }
}

// MARK: - AudioProcessingStep

public enum ProcessingKind: String, Codable, Sendable {
    case trimStart, trimEnd, gainDB, fadeInSeconds, fadeOutSeconds
}

public struct AudioProcessingStep: Codable, Sendable, Equatable {
    public var kind: ProcessingKind
    public var parameters: [String: Double]

    public init(kind: ProcessingKind, parameters: [String: Double] = [:]) {
        self.kind = kind
        self.parameters = parameters
    }
}

// MARK: - AudioQualityMetrics

public struct AudioQualityMetrics: Codable, Sendable, Equatable {
    public var peakDBFS: Double
    public var truePeakDBFS: Double
    public var rmsDBFS: Double
    public var noiseFloorDBFS: Double
    public var noiseFloorReliable: Bool
    public var replayGainDB: Double
    public var clipCount: Int
    public var dcOffset: Double
    public var leadingSilence: TimeInterval
    public var trailingSilence: TimeInterval
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channels: Int
    public var computedAt: Date
    public var analyzerVersion: Int

    public init(
        peakDBFS: Double,
        truePeakDBFS: Double,
        rmsDBFS: Double,
        noiseFloorDBFS: Double,
        noiseFloorReliable: Bool = true,
        replayGainDB: Double = 0,
        clipCount: Int,
        dcOffset: Double,
        leadingSilence: TimeInterval,
        trailingSilence: TimeInterval,
        duration: TimeInterval,
        sampleRate: Double,
        channels: Int,
        computedAt: Date = Date(), // determinism-exempt: convenience default; metrics pipeline passes Clock values
        analyzerVersion: Int = 1
    ) {
        self.peakDBFS = peakDBFS
        self.truePeakDBFS = truePeakDBFS
        self.rmsDBFS = rmsDBFS
        self.noiseFloorDBFS = noiseFloorDBFS
        self.noiseFloorReliable = noiseFloorReliable
        self.replayGainDB = replayGainDB
        self.clipCount = clipCount
        self.dcOffset = dcOffset
        self.leadingSilence = leadingSilence
        self.trailingSilence = trailingSilence
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.computedAt = computedAt
        self.analyzerVersion = analyzerVersion
    }
}

// MARK: - Take

public struct Take: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var paragraphID: UUID
    public var assetRef: AudioAssetReference
    public var origin: AudioOrigin
    public var recordedAt: Date
    public var duration: TimeInterval
    public var format: AudioFormatDescription
    public var processing: [AudioProcessingStep]
    public var metrics: AudioQualityMetrics?
    public var label: String?
    public var textHashAtRecording: String
    public var isArchived: Bool

    public init(
        id: UUID,
        paragraphID: UUID,
        assetRef: AudioAssetReference,
        origin: AudioOrigin,
        recordedAt: Date,
        duration: TimeInterval,
        format: AudioFormatDescription,
        processing: [AudioProcessingStep] = [],
        metrics: AudioQualityMetrics? = nil,
        label: String? = nil,
        textHashAtRecording: String,
        isArchived: Bool = false
    ) {
        self.id = id
        self.paragraphID = paragraphID
        self.assetRef = assetRef
        self.origin = origin
        self.recordedAt = recordedAt
        self.duration = duration
        self.format = format
        self.processing = processing
        self.metrics = metrics
        self.label = label
        self.textHashAtRecording = textHashAtRecording
        self.isArchived = isArchived
    }
}
