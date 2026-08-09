import Foundation

// MARK: - ExportScope

/// Which chapters the export covers (§16.11 step 1). LibriVox's actual
/// workflow posts one section at a time, so single-chapter export is required.
public enum ExportScope: Sendable, Equatable, Hashable {
    case wholeBook
    case chapters([UUID])
}

// MARK: - ExportOptions

public struct ExportOptions: Sendable, Equatable {
    /// IA: also produce MP3 derivatives (profile-defined bitrate) alongside
    /// the FLAC masters.
    public var includeMP3Derivatives: Bool
    /// IA: target `test_collection` (auto-purged dry run) instead of
    /// `opensource_audio` (§3.3.1).
    public var useTestCollection: Bool
    /// Retail: apply the mastering chain before encoding (§16.7).
    public var applyMastering: Bool
    /// Apple Books: AAC bitrate for the chapterized M4B (§3.4.4).
    public var m4bBitrateKbps: Int
    /// Retail: the user-chosen excerpt range for the retail sample (§3.4.3).
    public var retailSample: RetailSampleSelection?
    /// When false, re-exporting skips files whose content hash already matches
    /// the planned output (§16.12).
    public var overwriteExisting: Bool
    /// Write the validation report (JSON + HTML) into the package. Free users
    /// see it on screen; writing it to disk is a Pro export feature (§2.2).
    public var writeValidationReport: Bool
    /// Which chapters to export (§16.11 step 1).
    public var scope: ExportScope
    /// Timestamp used for generated manifests; injected so exports are
    /// deterministic in tests.
    public var generatedAt: Date
    /// The version string stamped into manifests and checklists.
    public var appVersion: String
    /// Relative-path → sha256 of output files a previous interrupted run already
    /// finished. When `overwriteExisting` is false and the on-disk file still
    /// matches, the pipeline skips re-encoding and reuses it (§13.3).
    public var resumeHashes: [String: String]
    /// Relative-path → duration of the resumed files, so a resumed run still
    /// reports correct section durations without re-decoding (§13.3).
    public var resumeDurations: [String: TimeInterval]

    public init(
        includeMP3Derivatives: Bool = false,
        useTestCollection: Bool = false,
        applyMastering: Bool = true,
        m4bBitrateKbps: Int = DestinationProfile.appleBooksAggregator.audio.bitrateKbps ?? 0,
        retailSample: RetailSampleSelection? = nil,
        overwriteExisting: Bool = true,
        writeValidationReport: Bool = true,
        scope: ExportScope = .wholeBook,
        generatedAt: Date = Date(), // determinism-exempt: convenience default; re-export passes explicit values from SystemClock
        appVersion: String = "Voxglass Studio 1.0",
        resumeHashes: [String: String] = [:],
        resumeDurations: [String: TimeInterval] = [:]
    ) {
        self.includeMP3Derivatives = includeMP3Derivatives
        self.useTestCollection = useTestCollection
        self.applyMastering = applyMastering
        self.m4bBitrateKbps = m4bBitrateKbps
        self.retailSample = retailSample
        self.overwriteExisting = overwriteExisting
        self.writeValidationReport = writeValidationReport
        self.scope = scope
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.resumeHashes = resumeHashes
        self.resumeDurations = resumeDurations
    }
}

// MARK: - ExportedFileRole

public enum ExportedFileRole: String, Sendable, Equatable {
    case chapter
    case sample
    case cover
    case manifest
    case checksum
    case checklist
    case report
    case master
    case secondaryAudio
}

// MARK: - ExportedFile

public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var role: ExportedFileRole
    public var chapterID: UUID?
    public var duration: TimeInterval?
    public var byteCount: Int64
    public var sha256: String
    /// Metrics measured on the *encoded output* (re-decoded at the destination
    /// format). Filled by the transcoder so builders can assert ACX-style
    /// compliance on the delivered file without re-decoding (§16.13 compliance).
    public var measured: AudioQualityMetrics?

    public init(
        url: URL,
        role: ExportedFileRole,
        chapterID: UUID? = nil,
        duration: TimeInterval? = nil,
        byteCount: Int64 = 0,
        sha256: String = "",
        measured: AudioQualityMetrics? = nil
    ) {
        self.url = url
        self.role = role
        self.chapterID = chapterID
        self.duration = duration
        self.byteCount = byteCount
        self.sha256 = sha256
        self.measured = measured
    }
}

// MARK: - ExportBundle

public struct ExportBundle: Sendable {
    public var destination: DestinationID
    public var rootURL: URL
    public var files: [ExportedFile]
    public var checklistURL: URL
    public var manifestURL: URL?
    public var checksumURL: URL?
    public var reportURL: URL?
    public var totalBytes: Int64
    public var totalDuration: TimeInterval
    public var warnings: [String]

    public init(
        destination: DestinationID,
        rootURL: URL,
        files: [ExportedFile],
        checklistURL: URL,
        manifestURL: URL? = nil,
        checksumURL: URL? = nil,
        reportURL: URL? = nil,
        totalBytes: Int64 = 0,
        totalDuration: TimeInterval = 0,
        warnings: [String] = []
    ) {
        self.destination = destination
        self.rootURL = rootURL
        self.files = files
        self.checklistURL = checklistURL
        self.manifestURL = manifestURL
        self.checksumURL = checksumURL
        self.reportURL = reportURL
        self.totalBytes = totalBytes
        self.totalDuration = totalDuration
        self.warnings = warnings
    }
}

// MARK: - ExportProgress

public struct ExportProgress: Sendable, Equatable {
    public var phase: ExportPhase
    public var completedUnits: Int
    public var totalUnits: Int
    public var currentFileName: String?
    public var fractionCompleted: Double
    public var estimatedRemaining: TimeInterval?
    /// Duration of the file named by `currentFileName` when `phase` is
    /// `.chapterFinished` — carried so `ResumableExportRunner` can persist
    /// resumed section durations without re-decoding (§13.3).
    public var completedDuration: TimeInterval?

    public init(
        phase: ExportPhase,
        completedUnits: Int = 0,
        totalUnits: Int = 0,
        currentFileName: String? = nil,
        fractionCompleted: Double = 0,
        estimatedRemaining: TimeInterval? = nil,
        completedDuration: TimeInterval? = nil
    ) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.currentFileName = currentFileName
        self.fractionCompleted = fractionCompleted
        self.estimatedRemaining = estimatedRemaining
        self.completedDuration = completedDuration
    }
}

public enum ExportPhase: String, Sendable {
    case validating
    case rendering
    case mastering
    case transcoding
    case tagging
    case writingArtifacts
    case hashing
    /// Emitted once per completed chapter output set, with `currentFileName`
    /// naming the chapter's primary output and `completedUnits` the chapter
    /// count finished. `ResumableExportRunner` keys its incremental
    /// `ExportRunRecord` updates on this event (§13.3).
    case chapterFinished
    case done
}
