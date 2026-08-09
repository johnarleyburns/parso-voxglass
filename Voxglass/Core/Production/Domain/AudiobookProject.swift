import Foundation

// MARK: - ProjectPurpose

public enum ProjectPurpose: String, Codable, Sendable, CaseIterable {
    case publicDomainCommunity
    case personal
    case commercial
}

// MARK: - RecordingDefaults

public struct RecordingDefaults: Codable, Sendable, Equatable {
    public var sampleRate: Double = 48_000
    public var bitDepth: Int = 24
    public var channels: Int = 1
    public var preRollSeconds: TimeInterval = 1.0
    public var warnOnClipping: Bool = true
    public var autoComputeMetrics: Bool = true
    public var inputDeviceUID: String?
    public var monitoringDeviceUID: String?
    public var monitoringEnabled: Bool = false

    public init(
        sampleRate: Double = 48_000,
        bitDepth: Int = 24,
        channels: Int = 1,
        preRollSeconds: TimeInterval = 1.0,
        warnOnClipping: Bool = true,
        autoComputeMetrics: Bool = true,
        inputDeviceUID: String? = nil,
        monitoringDeviceUID: String? = nil,
        monitoringEnabled: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.preRollSeconds = preRollSeconds
        self.warnOnClipping = warnOnClipping
        self.autoComputeMetrics = autoComputeMetrics
        self.inputDeviceUID = inputDeviceUID
        self.monitoringDeviceUID = monitoringDeviceUID
        self.monitoringEnabled = monitoringEnabled
    }
}

// MARK: - AssemblySettings

public struct AssemblySettings: Codable, Sendable, Equatable {
    public var paragraphGap: TimeInterval = 0.45
    public var sentenceGapBonus: TimeInterval = 0.0
    public var chapterHeadSilence: TimeInterval = 0.75
    public var chapterTailSilence: TimeInterval = 1.5
    public var sceneBreakExtraGap: TimeInterval = 1.0
    public var normalizeGapsFromTakeSilence: Bool = true
    /// Mockup 10 toggles (§11.1). Optional so projects persisted before these
    /// existed decode unchanged: synthesized Codable leaves a missing key nil.
    /// The computed accessors give each toggle a stable default.
    public var trimSilenceAtEdges: Bool?
    public var normalizeLoudness: Bool?

    /// Spec §11.1 / mockup 10 "Trim silence at take edges": detected from the
    /// take's measured edge silence (same analysis as import), never guessed.
    public var isTrimmingSilenceAtEdges: Bool { trimSilenceAtEdges ?? true }

    /// Mockup 10 "Normalise take-to-take loudness": ReplayGain applied at
    /// render, not as a destructive edit of the original.
    public var isNormalizingLoudness: Bool { normalizeLoudness ?? true }

    public init(
        paragraphGap: TimeInterval = 0.45,
        sentenceGapBonus: TimeInterval = 0.0,
        chapterHeadSilence: TimeInterval = 0.75,
        chapterTailSilence: TimeInterval = 1.5,
        sceneBreakExtraGap: TimeInterval = 1.0,
        normalizeGapsFromTakeSilence: Bool = true,
        trimSilenceAtEdges: Bool? = nil,
        normalizeLoudness: Bool? = nil
    ) {
        self.paragraphGap = paragraphGap
        self.sentenceGapBonus = sentenceGapBonus
        self.chapterHeadSilence = chapterHeadSilence
        self.chapterTailSilence = chapterTailSilence
        self.sceneBreakExtraGap = sceneBreakExtraGap
        self.normalizeGapsFromTakeSilence = normalizeGapsFromTakeSilence
        self.trimSilenceAtEdges = trimSilenceAtEdges
        self.normalizeLoudness = normalizeLoudness
    }
}

// MARK: - ProductionProfile

public struct ProductionProfile: Codable, Sendable, Equatable {
    public var purpose: ProjectPurpose
    public var recording: RecordingDefaults
    public var assembly: AssemblySettings
    public var intendedDestination: DestinationID
    public var isHiddenFromDevices: Bool
    public var autoSyncAcceptedTakes: Bool
    public var includeSourceTextInProjection: Bool
    public var proxyBitrateKbps: Int

    public init(
        purpose: ProjectPurpose = .personal,
        recording: RecordingDefaults = RecordingDefaults(),
        assembly: AssemblySettings = AssemblySettings(),
        intendedDestination: DestinationID = .librivox,
        isHiddenFromDevices: Bool = false,
        autoSyncAcceptedTakes: Bool = true,
        includeSourceTextInProjection: Bool = true,
        proxyBitrateKbps: Int = 80
    ) {
        self.purpose = purpose
        self.recording = recording
        self.assembly = assembly
        self.intendedDestination = intendedDestination
        self.isHiddenFromDevices = isHiddenFromDevices
        self.autoSyncAcceptedTakes = autoSyncAcceptedTakes
        self.includeSourceTextInProjection = includeSourceTextInProjection
        self.proxyBitrateKbps = proxyBitrateKbps
    }
}

// MARK: - AudiobookProject

public struct AudiobookProject: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var metadata: BookMetadata
    public var rights: RightsEvidence
    public var profile: ProductionProfile
    public var source: SourceDocument?
    public var chapters: [ProductionChapter]
    public var pronunciations: [PronunciationNote]
    public var createdAt: Date
    public var modifiedAt: Date
    public var schemaVersion: Int

    public var allParagraphs: [Paragraph] { chapters.flatMap(\.paragraphs) }
    public var recordedCount: Int { allParagraphs.count { $0.selectedTakeID != nil } }
    public var totalCount: Int { allParagraphs.count }
    public var percentRecorded: Double {
        totalCount == 0 ? 0 : Double(recordedCount) / Double(totalCount)
    }

    public init(
        id: UUID,
        metadata: BookMetadata,
        rights: RightsEvidence = RightsEvidence(),
        profile: ProductionProfile = ProductionProfile(),
        source: SourceDocument? = nil,
        chapters: [ProductionChapter] = [],
        pronunciations: [PronunciationNote] = [],
        createdAt: Date = Date(), // determinism-exempt: convenience default; persistence passes Clock values
        modifiedAt: Date = Date(), // determinism-exempt: convenience default; persistence passes Clock values
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.metadata = metadata
        self.rights = rights
        self.profile = profile
        self.source = source
        self.chapters = chapters
        self.pronunciations = pronunciations
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.schemaVersion = schemaVersion
    }
}
