import Foundation

/// Terminal states of an export run (§16.12). `running` marks an in-flight or
/// interrupted run; its `.partial` output directory is the resume artifact.
public enum ExportRunStatus: String, Codable, Sendable, Equatable {
    case running
    case succeeded
    case cancelled
    case failed
}

/// One row of the `export_run` table (§16.12): opened when an export starts,
/// written as files are produced, and closed on completion. `fileHashes`
/// (relativePath → sha256) is what makes skip-unchanged re-exports possible:
/// a planned output whose content hash matches the recorded hash is reported
/// "unchanged" instead of re-encoded. `fileDurations` keeps the same
/// relative-path keys so a resumed run can still report correct section
/// durations without re-decoding (§13.3).
public struct ExportRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var destination: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var outputPath: String?
    public var status: ExportRunStatus
    public var errorCode: String?
    public var fileCount: Int
    public var totalBytes: Int64
    public var fileHashes: [String: String]
    public var fileDurations: [String: TimeInterval]

    public init(
        id: UUID = UUID(), // determinism-exempt: storage identifier; tests inject explicit ids
        projectID: UUID,
        destination: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        outputPath: String? = nil,
        status: ExportRunStatus = .running,
        errorCode: String? = nil,
        fileCount: Int = 0,
        totalBytes: Int64 = 0,
        fileHashes: [String: String] = [:],
        fileDurations: [String: TimeInterval] = [:]
    ) {
        self.id = id
        self.projectID = projectID
        self.destination = destination
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputPath = outputPath
        self.status = status
        self.errorCode = errorCode
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.fileHashes = fileHashes
        self.fileDurations = fileDurations
    }
}
