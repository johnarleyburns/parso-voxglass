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

    private let store: any ProductionStore
    private let debounceMilliseconds: Int64
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        store: any ProductionStore,
        project: AudiobookProject,
        debounceMilliseconds: Int64 = 400
    ) {
        self.store = store
        self.project = project
        self.debounceMilliseconds = debounceMilliseconds
    }

    public func load() async {
        do {
            project = try await store.load()
            let roles = Dictionary(uniqueKeysWithValues: project.allParagraphs.map { ($0.id, $0.role) })
            self.roles = roles
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

    private func writeDraft(_ id: UUID) async {
        guard let text = draftTexts.removeValue(forKey: id) else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        do {
            try await store.updateParagraphText(
                id,
                text: normalized,
                hash: TextNormalizer.hash(normalized),
                at: Date()
            )
        } catch {
            self.error = "Failed to save paragraph: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func reloadSummaries() async {
        do {
            summaries = try await store.paragraphSummaries(chapterID: selectedChapterID)
        } catch {
            self.error = "Failed to load paragraphs: \(error.localizedDescription)"
        }
    }

    public func dismissError() {
        error = nil
    }
}
