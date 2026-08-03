import Foundation

public struct ProjectSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var author: String
    public var narrator: String
    public var percentRecorded: Double
    public var recordedCount: Int
    public var totalCount: Int
    public var flaggedCount: Int
    public var needsPickupCount: Int
    public var unapprovedCount: Int
    public var readyToExport: Bool
    public var purpose: ProjectPurpose
    public var modifiedAt: Date
    public var coverRef: AudioAssetReference?
    public var isHiddenFromDevices: Bool
    public var projectionRevision: Int

    public init(
        id: UUID, title: String = "", author: String = "", narrator: String = "",
        percentRecorded: Double = 0, recordedCount: Int = 0, totalCount: Int = 0,
        flaggedCount: Int = 0, needsPickupCount: Int = 0, unapprovedCount: Int = 0,
        readyToExport: Bool = false, purpose: ProjectPurpose = .publicDomainCommunity,
        modifiedAt: Date = Date(), coverRef: AudioAssetReference? = nil, // determinism-exempt: convenience default; callers pass Clock values
        isHiddenFromDevices: Bool = false, projectionRevision: Int = 0
    ) {
        self.id = id
        self.title = title; self.author = author; self.narrator = narrator
        self.percentRecorded = percentRecorded; self.recordedCount = recordedCount; self.totalCount = totalCount
        self.flaggedCount = flaggedCount; self.needsPickupCount = needsPickupCount; self.unapprovedCount = unapprovedCount
        self.readyToExport = readyToExport; self.purpose = purpose; self.modifiedAt = modifiedAt
        self.coverRef = coverRef; self.isHiddenFromDevices = isHiddenFromDevices; self.projectionRevision = projectionRevision
    }
}

public struct ParagraphSummary: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var chapterID: UUID
    public var ordinal: Int
    public var globalOrdinal: Int
    public var snippet: String
    public var reviewState: ReviewState
    public var hasSelectedTake: Bool
    public var takeCount: Int
    public var duration: TimeInterval?
    public var latestNoteSnippet: String?
    public var latestNoteTag: ReviewTag?
    public var isTextDrifted: Bool
    public var role: ParagraphRole

    public init(
        id: UUID, chapterID: UUID, ordinal: Int, globalOrdinal: Int = 0,
        snippet: String = "", reviewState: ReviewState = .unreviewed,
        hasSelectedTake: Bool = false, takeCount: Int = 0,
        duration: TimeInterval? = nil, latestNoteSnippet: String? = nil,
        latestNoteTag: ReviewTag? = nil, isTextDrifted: Bool = false,
        role: ParagraphRole = .body
    ) {
        self.id = id; self.chapterID = chapterID; self.ordinal = ordinal; self.globalOrdinal = globalOrdinal
        self.snippet = snippet; self.reviewState = reviewState; self.hasSelectedTake = hasSelectedTake
        self.takeCount = takeCount; self.duration = duration; self.latestNoteSnippet = latestNoteSnippet
        self.latestNoteTag = latestNoteTag; self.isTextDrifted = isTextDrifted; self.role = role
    }
}

public struct ProjectCounts: Sendable, Equatable {
    public var paragraphs: Int
    public var recorded: Int
    public var flagged: Int
    public var needsPickup: Int
    public var approved: Int
    public var unreviewed: Int
    public var unapproved: Int
    public var chapters: Int
    public var totalRecordedDuration: TimeInterval
    public var aiOriginSelected: Int
    /// Generated paragraphs (intro/outro/credits) that need no take.
    public var syntheticParagraphs: Int

    public init(
        paragraphs: Int = 0, recorded: Int = 0, flagged: Int = 0,
        needsPickup: Int = 0, approved: Int = 0, unreviewed: Int = 0,
        unapproved: Int = 0, chapters: Int = 0,
        totalRecordedDuration: TimeInterval = 0,
        aiOriginSelected: Int = 0, syntheticParagraphs: Int = 0
    ) {
        self.paragraphs = paragraphs; self.recorded = recorded; self.flagged = flagged
        self.needsPickup = needsPickup; self.approved = approved; self.unreviewed = unreviewed
        self.unapproved = unapproved
        self.chapters = chapters; self.totalRecordedDuration = totalRecordedDuration
        self.aiOriginSelected = aiOriginSelected
        self.syntheticParagraphs = syntheticParagraphs
    }
}

public protocol ProductionStore: Sendable {
    func load() async throws -> AudiobookProject
    func save(_ project: AudiobookProject) async throws
    func summary() async throws -> ProjectSummary

    /// Serializes long operations (import, script application, full save)
    /// against UI-driven mutations (§7.9). Implementations wrap the body in a
    /// single transaction; the UI can show a progress state around it.
    func withExclusiveWrite<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T

    func upsertChapter(_ chapter: ProductionChapter) async throws
    func upsertParagraph(_ paragraph: Paragraph) async throws
    func updateParagraphText(_ id: UUID, text: String, hash: String, at: Date) async throws
    func insertTake(_ take: Take) async throws
    func setSelectedTake(_ takeID: UUID?, forParagraph: UUID) async throws
    func setTakeMetrics(_ metrics: AudioQualityMetrics, forTake: UUID) async throws
    func archiveTake(_ id: UUID, archived: Bool) async throws

    func appendEvents(_ events: [ReviewEvent]) async throws
    func unappliedEvents() async throws -> [ReviewEvent]
    func markEventsApplied(_ ids: [UUID], at: Date) async throws
    func setReviewState(_ state: ReviewState, forParagraph: UUID) async throws
    func insertNote(_ note: ReviewNote) async throws
    func notes(forParagraph: UUID) async throws -> [ReviewNote]

    func paragraphSummaries(chapterID: UUID?) async throws -> [ParagraphSummary]
    func paragraphIDs(matching predicate: ReviewPredicate, order: QueueOrder) async throws -> [UUID]
    func counts() async throws -> ProjectCounts

    /// One pass that renumbers `global_ordinal` contiguously in document order
    /// (chapter.ordinal, paragraph.ordinal). MUST be called after import,
    /// split, merge, chapter reorder, and script application (§7.8); every
    /// "¶ N of M" label on every surface reads this column.
    func renumberGlobalOrdinals() async throws

    func cachedRender(forKey: String) async throws -> AudioAssetReference?
    func storeRender(_ ref: AudioAssetReference, key: String, chapterID: UUID, duration: TimeInterval) async throws

    /// Opens an export run row (`status = 'running'`, §16.12). A run left in
    /// `running` state after a crash/interrupt is what resumption detects.
    func openExportRun(projectID: UUID, destination: String) async throws -> ExportRunRecord
    /// Persists progress (file hashes, totals) and the terminal status.
    func updateExportRun(_ run: ExportRunRecord) async throws
    /// The most recent run row for a destination, any status.
    func latestExportRun(destination: String) async throws -> ExportRunRecord?
    /// The `running` run row for a destination, if one exists (resume prompt).
    func runningExportRun(destination: String) async throws -> ExportRunRecord?
    func cachedProxy(forTake: UUID, bitrateKbps: Int) async throws -> AudioAssetReference?
    func storeProxy(_ ref: AudioAssetReference, forTake: UUID, bitrateKbps: Int) async throws

    func syncValue(_ key: String) async throws -> String?
    func setSyncValue(_ key: String, _ value: String?) async throws
}
