import Foundation

/// The pure state of one CarPlay review session: the resolved queue payload, the
/// current position, and the action history (for Undo). Value type; the app-layer
/// controller owns one and mutates it.
public struct CarPlayReviewSession: Sendable, Equatable {
    public var payload: ResolvedQueuePayload
    public var currentIndex: Int
    public var autoAdvance: Bool
    public internal(set) var history: [CarPlayReviewCommand]

    public init(payload: ResolvedQueuePayload, currentIndex: Int = 0, autoAdvance: Bool? = nil) {
        self.payload = payload
        self.currentIndex = min(max(currentIndex, 0), max(payload.paragraphIDs.count - 1, 0))
        self.autoAdvance = autoAdvance ?? payload.autoAdvance
        self.history = []
    }

    public var count: Int { payload.paragraphIDs.count }

    public var currentParagraphID: UUID? {
        guard payload.paragraphIDs.indices.contains(currentIndex) else { return nil }
        return payload.paragraphIDs[currentIndex]
    }

    public var currentChapterLabel: String? {
        currentParagraphID.flatMap { payload.chapterLabels[$0] }
    }

    public var currentText: String? {
        currentParagraphID.flatMap { payload.texts[$0] }
    }

    public var currentNote: String? {
        currentParagraphID.flatMap { payload.notes[$0] }
    }

    public var currentTag: ReviewTag? {
        currentParagraphID.flatMap { payload.tags[$0] }
    }

    public var isAtStart: Bool { currentIndex == 0 }
    public var isAtEnd: Bool { currentIndex >= count - 1 }

    public var nextParagraphLabel: String? {
        guard currentIndex + 1 < count else { return nil }
        return payload.chapterLabels[payload.paragraphIDs[currentIndex + 1]]
    }

    public mutating func advance() {
        guard currentIndex + 1 < count else { return }
        currentIndex += 1
    }

    public mutating func rewind() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }
}

/// Maps `CarPlayReviewCommand`s to `ReviewEvent`s — the single place commands
/// become events (spec §18.3 rule 7), kept pure so it is unit-tested without a car.
/// Device is always `.carPlay`; `eventID`/`createdAt` are injectable for
/// deterministic tests.
public struct CarPlayReviewCommandMapper: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var event: ReviewEvent?
        public var session: CarPlayReviewSession
        public var confirmed: Bool

        public init(event: ReviewEvent?, session: CarPlayReviewSession, confirmed: Bool) {
            self.event = event
            self.session = session
            self.confirmed = confirmed
        }
    }

    public init() {}

    public func outcome(
        for command: CarPlayReviewCommand,
        in session: CarPlayReviewSession,
        eventID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> Outcome {
        var next = session
        guard let paragraphID = next.currentParagraphID else {
            return Outcome(event: nil, session: next, confirmed: false)
        }

        func event(_ type: ReviewEventType) -> ReviewEvent {
            ReviewEvent(
                id: eventID,
                projectID: next.payload.projectID,
                paragraphID: paragraphID,
                type: type,
                tag: next.currentTag,
                device: .carPlay,
                createdAt: createdAt
            )
        }

        switch command {
        case .approveAndNext:
            next.history.append(command)
            next.advance()
            return Outcome(event: event(.approve), session: next, confirmed: true)

        case .needsPickupAndNext:
            next.history.append(command)
            next.advance()
            return Outcome(event: event(.needsPickup), session: next, confirmed: true)

        case .keepFlaggedAndNext:
            next.history.append(command)
            next.advance()
            return Outcome(event: nil, session: next, confirmed: false)

        case .playNext:
            next.advance()
            return Outcome(event: nil, session: next, confirmed: false)

        case .undo:
            // Rewind to the paragraph the last action was applied to. Emit the
            // inverse event where one exists (pickup ↔ clearPickup); approve has
            // no inverse event in the fold, so undo simply returns the reviewer
            // to that paragraph.
            guard let last = next.history.popLast() else {
                return Outcome(event: nil, session: next, confirmed: false)
            }
            let inverse: ReviewEventType?
            switch last {
            case .needsPickupAndNext: inverse = .clearPickup
            case .approveAndNext, .keepFlaggedAndNext, .playNext, .undo: inverse = nil
            }
            next.rewind()
            let undoEvent: ReviewEvent? = inverse.flatMap { type in
                guard let paragraphID = next.currentParagraphID else { return nil }
                return ReviewEvent(
                    id: eventID,
                    projectID: next.payload.projectID,
                    paragraphID: paragraphID,
                    type: type,
                    tag: next.currentTag,
                    device: .carPlay,
                    createdAt: createdAt
                )
            }
            return Outcome(event: undoEvent, session: next, confirmed: inverse != nil)
        }
    }
}
