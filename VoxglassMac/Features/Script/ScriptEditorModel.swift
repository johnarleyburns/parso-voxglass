import Foundation
import Observation
import VoxglassCore

/// Backs the Script Editor (spec §18.1.6, mockup `05-script-editor`).
///
/// Renders chapter/paragraph structure with per-paragraph state chips and
/// inline text editing. Edits are debounced (400 ms) and flushed immediately
/// by `flush()` (⌘S), both through `ProductionStore.updateParagraphText` —
/// never through a whole-project `save()`. The paragraph list renders from
/// `paragraphSummaries(chapterID:)` so a 10,000-paragraph project never builds
/// every row eagerly (§7.5).
///
/// Structural edits (split, merge, reorder) snapshot the freshly-loaded project
/// before mutating, then `save()` + `renumberGlobalOrdinals()`, and register
/// the inverse on `undo` (§8.4).
@Observable @MainActor
public final class ScriptEditorModel {
    public private(set) var project: AudiobookProject
    public var selectedChapterID: UUID?
    public private(set) var summaries: [ParagraphSummary] = []
    public private(set) var roles: [UUID: ParagraphRole] = [:]
    /// Draft text keyed by paragraph ID; written to the store by the debounce.
    public private(set) var draftTexts: [UUID: String] = [:]
    public private(set) var isSaving = false
    public private(set) var error: String?
    public private(set) var editAnywayConfirmed: [UUID: Bool] = [:]
    public var searchQuery = ""
    public private(set) var searchMatches: [UUID] = []
    public var searchIndex = 0

    /// Recorded text snapshots for drift classification (§9.5). The domain
    /// model persists only `textHashAtRecording`; while a recording session
    /// is alive, `RecordingModel` feeds the full text into
    /// `sharedRecordedTexts` so the banner can distinguish `.minor` from
    /// `.semantic`. After a relaunch, hash mismatch alone yields the `.minor`
    /// "Text changed" chip.
    @MainActor
    public static var sharedRecordedTexts: [UUID: String] = [:]
    public var recordedTexts: [UUID: String] = [:]

    public let undo: StudioUndo
    private let store: any ProductionStore
    private let debounceMilliseconds: Int64
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        store: any ProductionStore,
        project: AudiobookProject,
        debounceMilliseconds: Int64 = 400,
        undo: StudioUndo = StudioUndo()
    ) {
        self.store = store
        self.project = project
        self.debounceMilliseconds = debounceMilliseconds
        self.undo = undo
        self.roles = Dictionary(uniqueKeysWithValues: project.allParagraphs.map { ($0.id, $0.role) })
    }

    // MARK: - Loading

    public func load() async {
        do {
            project = try await store.load()
            roles = Dictionary(uniqueKeysWithValues: project.allParagraphs.map { ($0.id, $0.role) })
            if selectedChapterID == nil {
                await selectChapter(project.chapters.first?.id)
            } else {
                await reloadSummaries()
            }
        } catch {
            self.error = "Failed to load script: \(error.localizedDescription)"
        }
    }

    public func selectChapter(_ id: UUID?) async {
        selectedChapterID = id
        await reloadSummaries()
    }

    public func paragraphText(_ id: UUID) -> String {
        draftTexts[id] ?? summaries.first(where: { $0.id == id })?.snippet ?? project.allParagraphs.first(where: { $0.id == id })?.text ?? ""
    }

    // MARK: - Inline editing (§8.4: edit text)

    /// Called by the text field on every change. Coalesces edits within the
    /// debounce window so a typing burst writes exactly one row.
    public func updateText(paragraphID: UUID, text: String) {
        draftTexts[paragraphID] = text
        saveTasks[paragraphID]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.debounceMilliseconds ?? 400))
            guard !Task.isCancelled, let self else { return }
            self.saveTasks[paragraphID] = nil
            await self.writeDraft(paragraphID)
        }
        saveTasks[paragraphID] = task
    }

    /// Flushes every pending edit immediately (⌘S and on chapter switch).
    public func flush() async {
        let pending = draftTexts.keys
        for id in pending {
            saveTasks[id]?.cancel()
            saveTasks[id] = nil
            await writeDraft(id)
        }
    }

    private func reloadSummaries() async {
        do {
            summaries = try await store.paragraphSummaries(chapterID: selectedChapterID)
        } catch {
            self.error = "Failed to load paragraphs: \(error.localizedDescription)"
        }
    }

    private func writeDraft(_ id: UUID) async {
        guard let text = draftTexts.removeValue(forKey: id) else { return }
        guard let previous = project.allParagraphs.first(where: { $0.id == id }) else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        undo.register(actionName: "Edit Text") { [weak self] in
            try? await self?.store.updateParagraphText(id, text: previous.text, hash: previous.textHash, at: previous.updatedAt)
        } redo: { [weak self] in
            try? await self?.store.updateParagraphText(id, text: normalized, hash: TextNormalizer.hash(normalized), at: Date())
        }
        do {
            try await store.updateParagraphText(
                id,
                text: normalized,
                hash: TextNormalizer.hash(normalized),
                at: Date()
            )
            if let index = project.allParagraphs.firstIndex(where: { $0.id == id }) {
                var para = project.allParagraphs[index]
                para.text = normalized
                para.textHash = TextNormalizer.hash(normalized)
                para.updatedAt = Date()
                replaceInProject(para)
            }
            await reloadSummaries()
        } catch {
            self.error = "Failed to save paragraph: \(error.localizedDescription)"
        }
        isSaving = false
    }

    // MARK: - Split / merge (§8.4, §9.6)

    /// Splits `paragraphID` at the given character offset. The first half
    /// keeps the original ID (takes stay attached); the second half is new.
    public func split(paragraphID: UUID, atCharacterOffset offset: Int) async {
        let snapshot: AudiobookProject
        do {
            snapshot = try await store.load()
        } catch {
            self.error = "Failed to load project: \(error.localizedDescription)"
            return
        }
        guard let (chapterIndex, paraIndex) = locate(snapshot, paragraphID: paragraphID) else { return }
        let splitter = ParagraphSplitter()
        let (first, second) = splitter.split(
            snapshot.chapters[chapterIndex].paragraphs[paraIndex],
            atCharacterOffset: offset,
            ids: UUIDGenerator(),
            clock: SystemClock()
        )
        var mutated = snapshot
        mutated.chapters[chapterIndex].paragraphs[paraIndex] = first
        mutated.chapters[chapterIndex].paragraphs.insert(second, at: paraIndex + 1)
        renumberChapterOrdinals(&mutated.chapters[chapterIndex])
        await applyStructuralMutation(mutated, snapshot: snapshot, actionName: "Split Paragraph")
    }

    /// Merges `paragraphID` with its next sibling (if any). The first
    /// paragraph's ID, takes, and selected take survive; the second's takes
    /// move onto it as archived takes (§8.4).
    public func merge(paragraphID: UUID) async {
        let snapshot: AudiobookProject
        do {
            snapshot = try await store.load()
        } catch {
            self.error = "Failed to load project: \(error.localizedDescription)"
            return
        }
        guard let (chapterIndex, paraIndex) = locate(snapshot, paragraphID: paragraphID) else { return }
        let chapter = snapshot.chapters[chapterIndex]
        guard paraIndex + 1 < chapter.paragraphs.count else { return }
        let first = chapter.paragraphs[paraIndex]
        let second = chapter.paragraphs[paraIndex + 1]
        let splitter = ParagraphSplitter()
        let merged = splitter.merge(first, second, clock: SystemClock())

        var mutated = snapshot
        mutated.chapters[chapterIndex].paragraphs[paraIndex] = merged
        mutated.chapters[chapterIndex].paragraphs.remove(at: paraIndex + 1)
        renumberChapterOrdinals(&mutated.chapters[chapterIndex])
        await applyStructuralMutation(mutated, snapshot: snapshot, actionName: "Merge Paragraphs")
    }

    /// Moves `chapterID` to `destinationIndex` within the chapter list.
    public func moveChapter(_ chapterID: UUID, to destinationIndex: Int) async {
        let snapshot: AudiobookProject
        do {
            snapshot = try await store.load()
        } catch {
            self.error = "Failed to load project: \(error.localizedDescription)"
            return
        }
        guard let from = snapshot.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        var mutated = snapshot
        let chapter = mutated.chapters.remove(at: from)
        let clamped = max(0, min(destinationIndex, mutated.chapters.count))
        mutated.chapters.insert(chapter, at: clamped)
        mutated.chapters.enumerated().forEach { i, ch in
            mutated.chapters[i].ordinal = i
        }
        await applyStructuralMutation(mutated, snapshot: snapshot, actionName: "Reorder Chapters")
    }

    private func applyStructuralMutation(_ mutated: AudiobookProject, snapshot: AudiobookProject, actionName: String) async {
        do {
            try await store.save(mutated)
            try await store.renumberGlobalOrdinals()
            undo.register(actionName: actionName) { [weak self] in
                guard let self else { return }
                try? await self.store.save(snapshot)
                try? await self.store.renumberGlobalOrdinals()
                await self.reloadAfterMutation()
            } redo: { [weak self] in
                guard let self else { return }
                try? await self.store.save(mutated)
                try? await self.store.renumberGlobalOrdinals()
                await self.reloadAfterMutation()
            }
            await reloadAfterMutation()
        } catch {
            self.error = "Failed to apply \(actionName): \(error.localizedDescription)"
        }
    }

    private func reloadAfterMutation() async {
        do {
            project = try await store.load()
            roles = Dictionary(uniqueKeysWithValues: project.allParagraphs.map { ($0.id, $0.role) })
            if let selected = selectedChapterID, !project.chapters.contains(where: { $0.id == selected }) {
                await selectChapter(project.chapters.first?.id)
            } else {
                await reloadSummaries()
            }
        } catch {
            self.error = "Failed to reload script: \(error.localizedDescription)"
        }
    }

    private func locate(_ project: AudiobookProject, paragraphID: UUID) -> (chapterIndex: Int, paraIndex: Int)? {
        for (ci, chapter) in project.chapters.enumerated() {
            if let pi = chapter.paragraphs.firstIndex(where: { $0.id == paragraphID }) {
                return (ci, pi)
            }
        }
        return nil
    }

    private func renumberChapterOrdinals(_ chapter: inout ProductionChapter) {
        chapter.paragraphs.enumerated().forEach { i, p in
            chapter.paragraphs[i].ordinal = i
        }
    }

    private func replaceInProject(_ paragraph: Paragraph) {
        for i in project.chapters.indices {
            if let j = project.chapters[i].paragraphs.firstIndex(where: { $0.id == paragraph.id }) {
                project.chapters[i].paragraphs[j] = paragraph
                return
            }
        }
    }

    // MARK: - Generated paragraphs (mockup `05`)

    public func isGenerated(_ id: UUID) -> Bool {
        guard let role = roles[id] else { return false }
        switch role {
        case .libriVoxIntro, .libriVoxOutro, .retailOpeningCredits, .retailClosingCredits:
            return true
        case .body, .chapterHeading:
            return false
        }
    }

    public func isEditable(_ id: UUID) -> Bool {
        if !isGenerated(id) { return true }
        return editAnywayConfirmed[id] == true
    }

    public func confirmEditAnyway(_ id: UUID) {
        editAnywayConfirmed[id] = true
    }

    // MARK: - Drift banner (§9.5)

    /// Drift classification for a paragraph: `.none` when the take's recorded
    /// hash matches the current text (or nothing is recorded); otherwise the
    /// full classifier when the recorded text is available, else `.minor`.
    public func driftKind(for paragraphID: UUID) -> DriftKind {
        guard let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }) else { return .none }
        guard let takeID = paragraph.selectedTakeID,
              let take = paragraph.takes.first(where: { $0.id == takeID }) else { return .none }
        if take.textHashAtRecording == paragraph.textHash { return .none }
        if let recorded = recordedTexts[paragraphID] ?? Self.sharedRecordedTexts[paragraphID] {
            return TextDriftDetector().classify(recorded: recorded, current: paragraph.text)
        }
        return .minor
    }

    // MARK: - Find (⌘F)

    public func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            searchMatches = []
            searchIndex = 0
            return
        }
        searchMatches = summaries
            .filter { summary in
                paragraphText(summary.id).lowercased().contains(query)
            }
            .map(\.id)
        searchIndex = searchMatches.isEmpty ? 0 : 0
    }

    public func nextMatch() -> UUID? {
        guard !searchMatches.isEmpty else { return nil }
        searchIndex = (searchIndex + 1) % searchMatches.count
        return searchMatches[searchIndex]
    }

    public func previousMatch() -> UUID? {
        guard !searchMatches.isEmpty else { return nil }
        searchIndex = (searchIndex - 1 + searchMatches.count) % searchMatches.count
        return searchMatches[searchIndex]
    }

    public var currentMatch: UUID? {
        searchMatches.isEmpty ? nil : searchMatches[searchIndex]
    }

    public func dismissError() {
        error = nil
    }
}
