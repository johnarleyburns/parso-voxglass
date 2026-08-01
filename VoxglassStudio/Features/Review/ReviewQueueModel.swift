import Foundation
import Observation
import VoxglassCore

/// Backs the Review Queue (spec §18.1.10). The queue is resolved once at start
/// and held stable for the session; items whose state changes to a state the
/// predicate excludes are marked *done* in place rather than vanishing
/// (§14.4). Every action is expressed as a `ReviewEvent` (§14.1); the fold is
/// applied locally for immediate UI and persisted through the store.
@Observable @MainActor
public final class ReviewQueueModel {
    public struct QueueItem: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var snippet: String
        public var state: ReviewState
        public var isDone: Bool

        public init(id: UUID, snippet: String, state: ReviewState, isDone: Bool = false) {
            self.id = id
            self.snippet = snippet
            self.state = state
            self.isDone = isDone
        }
    }

    public private(set) var items: [QueueItem] = []
    public private(set) var currentIndex: Int = 0
    public private(set) var currentParagraph: Paragraph?
    public private(set) var segments: [PlaybackSegment] = []
    public private(set) var isPlaying: Bool = false
    public private(set) var error: String?
    public private(set) var predicate: ReviewPredicate = .flagged
    public private(set) var notes: [ReviewNote] = []

    public var noteText: String = ""
    public var autoAdvance: Bool = true
    public var playContextSecond: Bool = false

    public var isAtEndOfQueue: Bool {
        !items.isEmpty && items[currentIndex].isDone && currentIndex == items.count - 1
    }

    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let player: any SegmentPlayer
    private var project: AudiobookProject

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        player: any SegmentPlayer
    ) {
        self.project = project
        self.store = store
        self.assets = assets
        self.player = player
    }

    public func load(predicate: ReviewPredicate) async {
        self.predicate = predicate
        let def = ReviewQueueDefinition(
            projectID: project.id,
            predicate: predicate,
            order: .documentOrder,
            autoAdvance: autoAdvance,
            playContextSecond: playContextSecond
        )
        let ids = ReviewQueueResolver().resolve(def, in: project)
        items = ids.compactMap { id in
            guard let para = project.allParagraphs.first(where: { $0.id == id }) else { return nil }
            return QueueItem(id: para.id, snippet: String(para.text.prefix(80)), state: para.reviewState)
        }
        segments = SegmentQueueBuilder().build(.reviewQueue(def), from: project, settings: project.profile.assembly)
        currentIndex = 0
        currentParagraph = paragraph(at: currentIndex)
        await reloadNotes()
        do {
            try await player.load(segments)
        } catch {
            self.error = "Failed to prepare playback: \(error.localizedDescription)"
        }
    }

    // MARK: - Transport

    public func togglePlayback() async {
        if isPlaying {
            await player.pause()
            isPlaying = false
        } else {
            do {
                try await player.play()
                isPlaying = true
            } catch {
                self.error = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    public func nextParagraph() async {
        guard currentIndex < items.count - 1 else { return }
        await move(to: currentIndex + 1)
    }

    public func previousParagraph() async {
        guard currentIndex > 0 else { return }
        await move(to: currentIndex - 1)
    }

    // MARK: - Actions (all expressed as events)

    public func approveAndNext() async {
        await action(.approve)
    }

    public func needsPickupAndNext() async {
        await action(.needsPickup)
    }

    public func keepFlagged() async {
        await advance()
    }

    public func clearPickup() async {
        await action(.clearPickup)
    }

    public func submitNote() async {
        guard let paraID = currentParagraph?.id else { return }
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteText = ""
        let event = ReviewEvent(projectID: project.id, paragraphID: paraID, type: .addNote, noteText: text, device: .mac)
        await apply(event)
        await reloadNotes()
    }

    // MARK: - Private

    private func action(_ type: ReviewEventType) async {
        guard let paraID = currentParagraph?.id else { return }
        let event = ReviewEvent(projectID: project.id, paragraphID: paraID, type: type, device: .mac)
        await apply(event)
        await advance()
    }

    private func apply(_ event: ReviewEvent) async {
        try? await store.appendEvents([event])
        // Fold locally so the UI updates immediately, independent of store
        // fold cadence.
        let folder = ReviewEventFolder()
        let states = currentStates
        let result = folder.fold([event], into: states)
        for (paraID, state) in result.states {
            setState(state, for: paraID)
            try? await store.setReviewState(state, forParagraph: paraID)
        }
        for note in result.notesToInsert {
            try? await store.insertNote(note)
        }
    }

    private func advance() async {
        guard !items.isEmpty else { return }
        updateItemsFromProject()
        if let current = currentParagraph?.id,
           let idx = items.firstIndex(where: { $0.id == current }) {
            items[idx].isDone = stateExcluded(items[idx].state)
        }
        var next = currentIndex + 1
        while next < items.count && items[next].isDone {
            next += 1
        }
        if next < items.count {
            await move(to: next)
        } else if currentIndex < items.count - 1 {
            items[currentIndex].isDone = true
            await move(to: currentIndex + 1)
        } else {
            items[currentIndex].isDone = true
            currentIndex = items.count - 1
            currentParagraph = paragraph(at: currentIndex)
            isPlaying = false
            await reloadNotes()
        }
    }

    private func move(to index: Int) async {
        currentIndex = index
        currentParagraph = paragraph(at: index)
        await reloadNotes()
        if autoAdvance, let paraID = currentParagraph?.id {
            try? await player.seek(toParagraph: paraID, offset: 0)
        }
    }

    private func updateItemsFromProject() {
        for i in items.indices {
            if let para = project.allParagraphs.first(where: { $0.id == items[i].id }) {
                items[i].state = para.reviewState
                items[i].snippet = String(para.text.prefix(80))
            }
        }
    }

    private func stateExcluded(_ state: ReviewState) -> Bool {
        switch predicate {
        case .flagged:
            return state != .flagged
        case .needsPickup:
            return state != .needsPickup
        case .unapproved:
            return state == .approved
        default:
            return false
        }
    }

    private func paragraph(at index: Int) -> Paragraph? {
        guard items.indices.contains(index) else { return nil }
        return project.allParagraphs.first { $0.id == items[index].id }
    }

    private var currentStates: [UUID: ReviewState] {
        var states: [UUID: ReviewState] = [:]
        for para in project.allParagraphs {
            states[para.id] = para.reviewState
        }
        return states
    }

    private func setState(_ state: ReviewState, for id: UUID) {
        for ci in project.chapters.indices {
            for pi in project.chapters[ci].paragraphs.indices where project.chapters[ci].paragraphs[pi].id == id {
                project.chapters[ci].paragraphs[pi].reviewState = state
            }
        }
    }

    private func reloadNotes() async {
        guard let id = currentParagraph?.id else {
            notes = []
            return
        }
        notes = (try? await store.notes(forParagraph: id)) ?? []
    }
}
