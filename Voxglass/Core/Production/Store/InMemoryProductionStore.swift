import Foundation

public actor InMemoryProductionStore: ProductionStore {
    private var project: AudiobookProject?
    private var events: [UUID: ReviewEvent] = [:]
    private var notes: [UUID: [ReviewNote]] = [:]
    private var renderCache: [String: AudioAssetReference] = [:]
    private var proxyCache: [UUID: AudioAssetReference] = [:]
    private var syncValues: [String: String] = [:]
    private var exportRuns: [ExportRunRecord] = []

    public init() {}

    public func load() async throws -> AudiobookProject {
        guard let project else { throw StoreError.projectNotFound }
        return project
    }

    public func save(_ project: AudiobookProject) async throws {
        // Matches the SQLite store: metrics written by `setTakeMetrics` are
        // carried forward when the incoming graph has none for that take.
        var incoming = project
        var stored: [UUID: AudioQualityMetrics] = [:]
        for take in self.project?.allParagraphs.flatMap(\.takes) ?? [] {
            if let metrics = take.metrics { stored[take.id] = metrics }
        }
        if !stored.isEmpty {
            for i in incoming.chapters.indices {
                for j in incoming.chapters[i].paragraphs.indices {
                    for k in incoming.chapters[i].paragraphs[j].takes.indices
                    where incoming.chapters[i].paragraphs[j].takes[k].metrics == nil {
                        incoming.chapters[i].paragraphs[j].takes[k].metrics = stored[incoming.chapters[i].paragraphs[j].takes[k].id]
                    }
                }
            }
        }
        self.project = incoming
    }

    public func withExclusiveWrite<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }

    public func summary() async throws -> ProjectSummary {
        guard let project else { throw StoreError.projectNotFound }
        let c = try await counts()
        return ProjectSummary(
            id: project.id,
            title: project.metadata.title,
            author: project.metadata.author,
            narrator: project.metadata.narrator,
            percentRecorded: c.paragraphs > 0 ? Double(c.recorded) / Double(c.paragraphs) : 0,
            recordedCount: c.recorded,
            totalCount: c.paragraphs,
            flaggedCount: c.flagged,
            needsPickupCount: c.needsPickup,
            unapprovedCount: c.unapproved,
            readyToExport: c.paragraphs > 0 && c.recorded >= c.paragraphs - c.syntheticParagraphs && c.needsPickup == 0,
            purpose: project.profile.purpose,
            modifiedAt: project.modifiedAt,
            coverRef: project.metadata.coverRef,
            isHiddenFromDevices: project.profile.isHiddenFromDevices
        )
    }

    public func upsertChapter(_ chapter: ProductionChapter) async throws {
        guard var project else { throw StoreError.projectNotFound }
        project.chapters.removeAll { $0.id == chapter.id }
        project.chapters.append(chapter)
        project.chapters.sort { $0.ordinal < $1.ordinal }
        self.project = project
    }

    public func upsertParagraph(_ paragraph: Paragraph) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            if let idx = project.chapters[i].paragraphs.firstIndex(where: { $0.id == paragraph.id }) {
                project.chapters[i].paragraphs[idx] = paragraph
                self.project = project
                return
            }
        }
        throw StoreError.notFound(paragraph.id)
    }

    public func updateParagraphText(_ id: UUID, text: String, hash: String, at date: Date) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices where project.chapters[i].paragraphs[j].id == id {
                project.chapters[i].paragraphs[j].text = text
                project.chapters[i].paragraphs[j].textHash = hash
                project.chapters[i].paragraphs[j].updatedAt = date
                self.project = project
                return
            }
        }
    }

    public func insertTake(_ take: Take) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices where project.chapters[i].paragraphs[j].id == take.paragraphID {
                project.chapters[i].paragraphs[j].takes.append(take)
                self.project = project
                return
            }
        }
    }

    public func setSelectedTake(_ takeID: UUID?, forParagraph paragraphID: UUID) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices where project.chapters[i].paragraphs[j].id == paragraphID {
                project.chapters[i].paragraphs[j].selectedTakeID = takeID
                self.project = project
                return
            }
        }
    }

    public func setTakeMetrics(_ metrics: AudioQualityMetrics, forTake takeID: UUID) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices {
                for k in project.chapters[i].paragraphs[j].takes.indices where project.chapters[i].paragraphs[j].takes[k].id == takeID {
                    project.chapters[i].paragraphs[j].takes[k].metrics = metrics
                    self.project = project
                    return
                }
            }
        }
    }

    public func archiveTake(_ id: UUID, archived: Bool) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices {
                for k in project.chapters[i].paragraphs[j].takes.indices where project.chapters[i].paragraphs[j].takes[k].id == id {
                    project.chapters[i].paragraphs[j].takes[k].isArchived = archived
                    self.project = project
                    return
                }
            }
        }
    }

    public func appendEvents(_ events: [ReviewEvent]) async throws {
        for event in events where self.events[event.id] == nil {
            self.events[event.id] = event
        }
    }

    public func unappliedEvents() async throws -> [ReviewEvent] {
        events.values.filter { $0.appliedAt == nil }
    }

    public func markEventsApplied(_ ids: [UUID], at date: Date) async throws {
        for id in ids {
            if var evt = events[id] {
                evt = ReviewEvent(
                    id: evt.id, projectID: evt.projectID, paragraphID: evt.paragraphID,
                    type: evt.type, noteText: evt.noteText, tag: evt.tag,
                    device: evt.device, createdAt: evt.createdAt,
                    appliedAt: date, origin: evt.origin
                )
                events[id] = evt
            }
        }
    }

    public func setReviewState(_ state: ReviewState, forParagraph id: UUID) async throws {
        guard var project else { throw StoreError.projectNotFound }
        for i in project.chapters.indices {
            for j in project.chapters[i].paragraphs.indices where project.chapters[i].paragraphs[j].id == id {
                project.chapters[i].paragraphs[j].reviewState = state
                self.project = project
                return
            }
        }
    }

    public func insertNote(_ note: ReviewNote) async throws {
        notes[note.paragraphID, default: []].append(note)
    }

    public func notes(forParagraph paragraphID: UUID) async throws -> [ReviewNote] {
        notes[paragraphID] ?? []
    }

    public func paragraphSummaries(chapterID: UUID?) async throws -> [ParagraphSummary] {
        guard let project else { return [] }
        var result: [ParagraphSummary] = []
        var global = 0
        for ch in project.chapters {
            if let cid = chapterID, ch.id != cid { continue }
            for para in ch.paragraphs {
                let selectedTake = para.takes.first { $0.id == para.selectedTakeID }
                let paraNotes = notes[para.id] ?? []
                let summary = ParagraphSummary(
                    id: para.id,
                    chapterID: ch.id,
                    ordinal: para.ordinal,
                    globalOrdinal: global,
                    snippet: String(para.text.prefix(90)),
                    reviewState: para.reviewState,
                    hasSelectedTake: para.selectedTakeID != nil,
                    takeCount: para.takes.count,
                    duration: selectedTake?.duration,
                    latestNoteSnippet: paraNotes.last?.text,
                    latestNoteTag: paraNotes.last?.tag,
                    role: para.role
                )
                result.append(summary)
                global += 1
            }
        }
        return result
    }

    /// In-memory summaries derive `globalOrdinal` on the fly in document
    /// order, so there is nothing to renumber (the SQLite projection keeps the
    /// column). The method exists to satisfy the protocol (§7.8).
    public func renumberGlobalOrdinals() async throws {}

    public func paragraphIDs(matching predicate: ReviewPredicate, order: QueueOrder) async throws -> [UUID] {
        guard let project else { return [] }
        var ids: [UUID] = []
        for ch in project.chapters {
            for para in ch.paragraphs {
                var matches = false
                switch predicate {
                case .allRecorded:
                    matches = para.selectedTakeID != nil
                case .flagged:
                    matches = para.reviewState == .flagged
                case .needsPickup:
                    matches = para.reviewState == .needsPickup
                case .unapproved:
                    matches = para.selectedTakeID != nil && para.reviewState != .approved
                case .unreviewed:
                    matches = para.selectedTakeID != nil && para.reviewState == .unreviewed
                case .selectedParagraphs(let ids):
                    matches = ids.contains(para.id)
                case .chapter(let chapterID):
                    matches = chapterID == ch.id
                case .tag:
                    matches = para.selectedTakeID != nil
                }
                if matches { ids.append(para.id) }
            }
        }
        return ids
    }

    public func counts() async throws -> ProjectCounts {
        guard let project else { return ProjectCounts() }
        var counts = ProjectCounts()
        var totalDur: TimeInterval = 0
        var aiCount = 0
        var synthetic = 0
        for ch in project.chapters {
            counts.chapters += 1
            for para in ch.paragraphs {
                counts.paragraphs += 1
                switch para.role {
                case .libriVoxIntro, .libriVoxOutro, .retailOpeningCredits, .retailClosingCredits:
                    synthetic += 1
                case .body, .chapterHeading:
                    break
                }
                if let selectedTake = para.takes.first(where: { $0.id == para.selectedTakeID }) {
                    counts.recorded += 1
                    totalDur += selectedTake.duration
                    if case .aiImported = selectedTake.origin { aiCount += 1 }
                }
                switch para.reviewState {
                case .flagged: counts.flagged += 1
                case .needsPickup: counts.needsPickup += 1
                case .approved: counts.approved += 1
                case .unreviewed: counts.unreviewed += 1
                }
            }
        }
        counts.totalRecordedDuration = totalDur
        counts.aiOriginSelected = aiCount
        counts.syntheticParagraphs = synthetic
        counts.unapproved = max(0, counts.recorded - counts.approved)
        return counts
    }

    public func cachedRender(forKey key: String) async throws -> AudioAssetReference? { renderCache[key] }
    public func storeRender(_ ref: AudioAssetReference, key: String, chapterID: UUID, duration: TimeInterval) async throws { renderCache[key] = ref }
    public func cachedProxy(forTake takeID: UUID, bitrateKbps: Int) async throws -> AudioAssetReference? { proxyCache[takeID] }
    public func storeProxy(_ ref: AudioAssetReference, forTake takeID: UUID, bitrateKbps: Int) async throws { proxyCache[takeID] = ref }
    public func syncValue(_ key: String) async throws -> String? { syncValues[key] }
    public func setSyncValue(_ key: String, _ value: String?) async throws {
        if let v = value { syncValues[key] = v } else { syncValues.removeValue(forKey: key) }
    }

    // MARK: - Export runs (§16.12)

    public func openExportRun(projectID: UUID, destination: String) async throws -> ExportRunRecord {
        let run = ExportRunRecord(projectID: projectID, destination: destination, startedAt: Date(timeIntervalSince1970: 0))
        exportRuns.append(run)
        return run
    }

    public func updateExportRun(_ run: ExportRunRecord) async throws {
        if let index = exportRuns.firstIndex(where: { $0.id == run.id }) {
            exportRuns[index] = run
        } else {
            exportRuns.append(run)
        }
    }

    public func latestExportRun(destination: String) async throws -> ExportRunRecord? {
        exportRuns.filter { $0.destination == destination }
            .max(by: { $0.startedAt < $1.startedAt })
    }

    public func runningExportRun(destination: String) async throws -> ExportRunRecord? {
        exportRuns.filter { $0.destination == destination && $0.status == .running }
            .max(by: { $0.startedAt < $1.startedAt })
    }
}
