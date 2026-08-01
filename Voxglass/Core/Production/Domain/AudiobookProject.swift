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

    public init(
        paragraphGap: TimeInterval = 0.45,
        sentenceGapBonus: TimeInterval = 0.0,
        chapterHeadSilence: TimeInterval = 0.75,
        chapterTailSilence: TimeInterval = 1.5,
        sceneBreakExtraGap: TimeInterval = 1.0,
        normalizeGapsFromTakeSilence: Bool = true
    ) {
        self.paragraphGap = paragraphGap
        self.sentenceGapBonus = sentenceGapBonus
        self.chapterHeadSilence = chapterHeadSilence
        self.chapterTailSilence = chapterTailSilence
        self.sceneBreakExtraGap = sceneBreakExtraGap
        self.normalizeGapsFromTakeSilence = normalizeGapsFromTakeSilence
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
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
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
