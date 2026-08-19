import Foundation

public struct ReviewEventFolder: Sendable {

    public func fold(_ events: [ReviewEvent], into initial: [UUID: ReviewState]) -> FoldResult {
        let sorted = events.sorted { a, b in
            if a.createdAt < b.createdAt { return true }
            if a.createdAt > b.createdAt { return false }
            return a.id.uuidString < b.id.uuidString
        }

        var states = initial
        var notes: [ReviewNote] = []
        var changed: Set<UUID> = []
        var eventsByParagraph: [UUID: [(event: ReviewEvent, index: Int)]] = [:]

        for (idx, event) in sorted.enumerated() {
            eventsByParagraph[event.paragraphID, default: []].append((event, idx))
        }

        for (paragraphID, eventList) in eventsByParagraph {
            for (event, _) in eventList {
                let prevState = states[paragraphID] ?? .unreviewed
                var newState: ReviewState

                switch event.type {
                case .flag:
                    newState = .flagged
                case .unflag:
                    newState = prevState == .flagged ? .unreviewed : prevState
                case .approve:
                    newState = .approved
                case .needsPickup:
                    newState = .needsPickup
                case .clearPickup:
                    newState = prevState == .needsPickup ? .unreviewed : prevState
                case .addNote:
                    newState = prevState == .unreviewed ? .flagged : prevState
                    if let noteText = event.noteText {
                        let note = ReviewNote(
                            paragraphID: paragraphID,
                            text: noteText,
                            tag: event.tag,
                            device: event.device,
                            timecode: nil,
                            createdAt: event.createdAt
                        )
                        notes.append(note)
                    }
                case .voiceNoteRequested:
                    newState = prevState == .unreviewed ? .flagged : prevState
                    let note = ReviewNote(
                        paragraphID: paragraphID,
                        text: "(voice note — complete on iPhone)",
                        tag: event.tag,
                        device: event.device,
                        timecode: nil,
                        createdAt: event.createdAt
                    )
                    notes.append(note)
                case .resolveNote:
                    newState = prevState
                }

                if newState != prevState {
                    states[paragraphID] = newState
                    changed.insert(paragraphID)
                }
            }
        }

        // Pickup stickiness: if any .needsPickup event exists, .approve from a different
        // device within 60 seconds must not override it.
        for (paragraphID, eventList) in eventsByParagraph {
            let hasPickup = eventList.contains { $0.event.type == .needsPickup }
            guard hasPickup else { continue }

            for (event, _) in eventList where event.type == .approve {
                let approvalTime = event.createdAt.timeIntervalSince1970
                let nearbyPickup = eventList.contains { other in
                    other.event.type == .needsPickup
                        && other.event.device != event.device
                        && abs(other.event.createdAt.timeIntervalSince1970 - approvalTime) < 60
                }
                if nearbyPickup {
                    states[paragraphID] = .needsPickup
                    changed.insert(paragraphID)
                    break
                }
            }
        }

        return FoldResult(states: states, notesToInsert: notes, changedParagraphIDs: changed)
    }

    public init() {}
}

public struct FoldResult: Sendable {
    public var states: [UUID: ReviewState]
    public var notesToInsert: [ReviewNote]
    public var changedParagraphIDs: Set<UUID>

    public init(
        states: [UUID: ReviewState] = [:],
        notesToInsert: [ReviewNote] = [],
        changedParagraphIDs: Set<UUID> = []
    ) {
        self.states = states
        self.notesToInsert = notesToInsert
        self.changedParagraphIDs = changedParagraphIDs
    }
}
