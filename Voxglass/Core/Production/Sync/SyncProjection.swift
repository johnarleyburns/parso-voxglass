import Foundation

// MARK: - ChapterProjection

/// The read-only view of one chapter that is published to CloudKit (spec §13.2).
/// Consumers use it to render chapter lists and per-chapter completion without
/// ever seeing a full `ProductionChapter`.
public struct ChapterProjection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var ordinal: Int
    public var title: String
    public var role: ChapterRole
    public var paragraphCount: Int
    public var recordedCount: Int
    public var duration: TimeInterval

    public init(
        id: UUID,
        projectID: UUID,
        ordinal: Int,
        title: String,
        role: ChapterRole = .body,
        paragraphCount: Int = 0,
        recordedCount: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.ordinal = ordinal
        self.title = title
        self.role = role
        self.paragraphCount = paragraphCount
        self.recordedCount = recordedCount
        self.duration = duration
    }
}

// MARK: - ParagraphProjection

/// The read-only view of one paragraph. `takeID` and `proxySourceSHA` are present
/// only when the paragraph has a selected take; unrecorded paragraphs appear so the
/// phone can show progress and paragraph lists, but carry no audio.
public struct ParagraphProjection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chapterID: UUID
    public var projectID: UUID
    public var ordinal: Int
    public var globalOrdinal: Int
    public var text: String?
    public var reviewState: ReviewState
    public var takeID: UUID?
    public var duration: TimeInterval
    /// SHA-256 of the selected take's source asset — the change detector for proxies.
    public var proxySourceSHA: String?
    public var latestNoteText: String?
    public var latestNoteTag: ReviewTag?
    /// `AudioOrigin.storageKind` of the selected take, for the on-device AI audit.
    public var originKind: String

    public init(
        id: UUID,
        chapterID: UUID,
        projectID: UUID,
        ordinal: Int,
        globalOrdinal: Int = 0,
        text: String? = nil,
        reviewState: ReviewState = .unreviewed,
        takeID: UUID? = nil,
        duration: TimeInterval = 0,
        proxySourceSHA: String? = nil,
        latestNoteText: String? = nil,
        latestNoteTag: ReviewTag? = nil,
        originKind: String = "none"
    ) {
        self.id = id
        self.chapterID = chapterID
        self.projectID = projectID
        self.ordinal = ordinal
        self.globalOrdinal = globalOrdinal
        self.text = text
        self.reviewState = reviewState
        self.takeID = takeID
        self.duration = duration
        self.proxySourceSHA = proxySourceSHA
        self.latestNoteText = latestNoteText
        self.latestNoteTag = latestNoteTag
        self.originKind = originKind
    }
}

// MARK: - SyncProjection

/// The complete, selected-takes-only view of a project that is published to the
/// private CloudKit zone and consumed by phone/watch/CarPlay review (spec §13.3).
/// `revision` is the monotonic staleness check; `watchPinnedParagraphIDs` marks the
/// paragraphs "Prepare Offline Queue" chose for the watch (spec §13.8).
public struct SyncProjection: Codable, Sendable, Equatable {
    public var project: ProjectSummary
    public var chapters: [ChapterProjection]
    public var paragraphs: [ParagraphProjection]
    public var revision: Int
    public var narrationOrigin: NarrationOrigin
    public var watchPinnedParagraphIDs: [UUID]

    public init(
        project: ProjectSummary,
        chapters: [ChapterProjection] = [],
        paragraphs: [ParagraphProjection] = [],
        revision: Int = 0,
        narrationOrigin: NarrationOrigin = .humanOnly,
        watchPinnedParagraphIDs: [UUID] = []
    ) {
        self.project = project
        self.chapters = chapters
        self.paragraphs = paragraphs
        self.revision = revision
        self.narrationOrigin = narrationOrigin
        self.watchPinnedParagraphIDs = watchPinnedParagraphIDs
    }
}

// MARK: - ProjectionPolicy

/// Encodes *what* may be projected (spec §13.3). The builder applies the policy;
/// the publisher uses `shouldProject` to decide whether a publish is permitted.
public struct ProjectionPolicy: Sendable, Equatable {
    public var includeSourceText: Bool
    public var proxyBitrateKbps: Int

    public init(includeSourceText: Bool = true, proxyBitrateKbps: Int = 80) {
        self.includeSourceText = includeSourceText
        self.proxyBitrateKbps = proxyBitrateKbps
    }

    /// Hidden projects are never projected (§13.3 rule 4).
    public func shouldProject(_ project: AudiobookProject) -> Bool {
        !project.profile.isHiddenFromDevices
    }

    /// Text is included only when the project owner allowed it (§13.3 rule 5) —
    /// a commercial project under NDA may preview audio only.
    public func text(for paragraph: Paragraph) -> String? {
        includeSourceText ? paragraph.text : nil
    }

    /// The `originKind` string recorded on a paragraph projection: the selected
    /// take's origin storage kind, so the phone can render the AI audit.
    public func originKind(for take: Take?) -> String {
        guard let take else { return "none" }
        return take.origin.storageKind
    }

    /// `humanOnly` when every *selected* take is human narration, else
    /// `containsImportedAI`. Unselected takes never taint the projection (§3.2.6).
    public func narrationOrigin(for project: AudiobookProject) -> NarrationOrigin {
        EligibilityProfile.evaluate(project).narrationOrigin
    }
}

// MARK: - ProjectionBuilder

/// Turns a project into its projection (spec §13.3). Pure and deterministic.
public struct ProjectionBuilder: Sendable {
    public var policy: ProjectionPolicy

    public init(policy: ProjectionPolicy = ProjectionPolicy()) {
        self.policy = policy
    }

    /// Returns `nil` when the project must not be published (hidden from devices).
    /// `latestNotes` keyed by paragraph ID supplies the denormalized note preview the
    /// phone list shows; when omitted, notes are absent from the projection.
    public func projection(
        from project: AudiobookProject,
        counts: ProjectCounts,
        revision: Int,
        watchPinnedParagraphIDs: [UUID] = [],
        latestNotes: [UUID: ReviewNote] = [:]
    ) -> SyncProjection? {
        guard policy.shouldProject(project) else { return nil }

        var globalOrdinal = 0
        var chapters: [ChapterProjection] = []
        var paragraphs: [ParagraphProjection] = []

        for chapter in project.chapters {
            var recordedCount = 0
            var chapterDuration: TimeInterval = 0

            for paragraph in chapter.paragraphs {
                let selected = selectedTake(of: paragraph)
                if selected != nil {
                    recordedCount += 1
                    chapterDuration += selected?.duration ?? 0
                }
                let note = latestNotes[paragraph.id]

                paragraphs.append(ParagraphProjection(
                    id: paragraph.id,
                    chapterID: chapter.id,
                    projectID: project.id,
                    ordinal: paragraph.ordinal,
                    globalOrdinal: globalOrdinal,
                    text: policy.text(for: paragraph),
                    reviewState: paragraph.reviewState,
                    takeID: selected?.id,
                    duration: selected?.duration ?? 0,
                    proxySourceSHA: selected?.assetRef.sha256,
                    latestNoteText: note?.text,
                    latestNoteTag: note?.tag,
                    originKind: policy.originKind(for: selected)
                ))
                globalOrdinal += 1
            }

            chapters.append(ChapterProjection(
                id: chapter.id,
                projectID: project.id,
                ordinal: chapter.ordinal,
                title: chapter.title,
                role: chapter.role,
                paragraphCount: chapter.paragraphs.count,
                recordedCount: recordedCount,
                duration: chapterDuration
            ))
        }

        let percentRecorded = counts.paragraphs == 0
            ? 0
            : Double(counts.recorded) / Double(counts.paragraphs)

        let summary = ProjectSummary(
            id: project.id,
            title: project.metadata.title,
            author: project.metadata.author,
            narrator: project.metadata.narrator,
            percentRecorded: percentRecorded,
            recordedCount: counts.recorded,
            totalCount: counts.paragraphs,
            flaggedCount: counts.flagged,
            needsPickupCount: counts.needsPickup,
            unapprovedCount: max(0, counts.recorded - counts.approved),
            readyToExport: counts.needsPickup == 0 && counts.paragraphs > 0 && counts.recorded == counts.paragraphs,
            purpose: project.profile.purpose,
            modifiedAt: project.modifiedAt,
            coverRef: project.metadata.coverRef,
            isHiddenFromDevices: project.profile.isHiddenFromDevices,
            projectionRevision: revision
        )

        return SyncProjection(
            project: summary,
            chapters: chapters,
            paragraphs: paragraphs,
            revision: revision,
            narrationOrigin: policy.narrationOrigin(for: project),
            watchPinnedParagraphIDs: watchPinnedParagraphIDs
        )
    }

    private func selectedTake(of paragraph: Paragraph) -> Take? {
        guard let id = paragraph.selectedTakeID else { return nil }
        return paragraph.takes.first { $0.id == id }
    }
}
