import Foundation

// MARK: - RecordingRemoteAction

/// One of the five watch recording-remote commands (spec §14.3). The watch only
/// ever sends commands; the iPhone is the only writer of takes and review state.
public enum RecordingRemoteAction: String, Codable, Sendable, CaseIterable, Equatable {
    /// Start a take on the current paragraph (only while the capture is armed).
    case record
    /// Stop the live take; the phone finalizes and ingests it.
    case stop
    /// Stop any live take, accept the paragraph, and advance to the next one.
    case accept
    /// Stop any live take and start a fresh one on the same paragraph.
    case retake
    /// Stop any live take, flag the paragraph, and advance to the next one.
    case flag
}

// MARK: - RecordingRemoteCommand

/// A command the watch sends to the iPhone's active recording session
/// (§14.3). Commands are idempotent by `(sessionID, sequence)`: a duplicated
/// `transferUserInfo` carrying the same `(sessionID, sequence)` MUST NOT produce
/// a second take. The phone acknowledges and drops commands that arrive while
/// the capture is not armed or recording.
public struct RecordingRemoteCommand: Codable, Sendable, Equatable {
    /// The phone's recording session id (changes whenever a session starts, so a
    /// stale remote cannot act on a later session).
    public var sessionID: UUID
    /// Monotonic per session; the phone dedupes on it.
    public var sequence: Int
    public var action: RecordingRemoteAction

    public init(sessionID: UUID, sequence: Int, action: RecordingRemoteAction) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.action = action
    }
}

// MARK: - RecordingRemoteStatus

/// The live state the iPhone relays to the watch while a recording session is
/// active (§14.3). No audio crosses the link; the watch shows this telemetry and
/// sends `RecordingRemoteCommand`s back.
public struct RecordingRemoteStatus: Codable, Sendable, Equatable {
    /// The session this status describes; the watch targets commands at it.
    public var sessionID: UUID
    /// The paragraph being recorded, so the watch can play a proxy it already
    /// cached for review (no audio crosses the link live — §14.3).
    public var paragraphID: UUID?
    /// 1-based paragraph number within the work.
    public var paragraphNumber: Int
    /// The current chapter's title, or "" when none.
    public var chapterTitle: String
    /// Seconds elapsed on the live take; 0 when not recording.
    public var elapsedSeconds: TimeInterval
    /// The latest input level in dBFS, or -60 when not recording.
    public var levelDBFS: Float
    /// True while the capture is recording a take.
    public var isRecording: Bool
    /// True while the capture is armed or monitoring — the states in which a
    /// remote command is honored.
    public var isArmed: Bool

    public init(
        sessionID: UUID,
        paragraphID: UUID? = nil,
        paragraphNumber: Int,
        chapterTitle: String,
        elapsedSeconds: TimeInterval,
        levelDBFS: Float,
        isRecording: Bool,
        isArmed: Bool
    ) {
        self.sessionID = sessionID
        self.paragraphID = paragraphID
        self.paragraphNumber = paragraphNumber
        self.chapterTitle = chapterTitle
        self.elapsedSeconds = elapsedSeconds
        self.levelDBFS = levelDBFS
        self.isRecording = isRecording
        self.isArmed = isArmed
    }
}

// MARK: - RecordingRemoteOutcome

/// What the phone did with a command (§14.3).
public enum RecordingRemoteOutcome: Sendable, Equatable {
    /// The command's action was dispatched to the session handler.
    case accepted
    /// The `(sessionID, sequence)` was already seen — the command is a duplicate
    /// transfer and is ignored.
    case duplicate
    /// The capture is not armed or recording; the command was acknowledged and
    /// dropped, and the watch shows "iPhone isn't recording."
    case dropped
    /// The command targeted a different session (stale remote).
    case foreignSession
}

// MARK: - RecordingRemoteCoordinator

/// The phone-side gate for watch recording-remote commands (§14.3). It enforces
/// the two MUSTs of the feature:
///
/// 1. **Idempotency by `(sessionID, sequence)`** — a duplicated transfer never
///    dispatches a second action, so it can never produce a second take.
/// 2. **State gating** — a command is only honored while the capture is armed
///    (`prepared`/`monitoring`) or `recording`; otherwise it is dropped.
///
/// The coordinator is pure Core but deliberately `@MainActor`: the recording
/// session it serves lives in the main-actor flow, and the state/action closures
/// read that flow's live capture state. Tests drive it with a fake state and a
/// recording fake handler (spec §16.2 `RecordingRemoteTests`).
@MainActor
public final class RecordingRemoteCoordinator {
    /// The session this coordinator serves; commands for other sessions are
    /// dropped as foreign.
    public let sessionID: UUID

    private var lastSequence = 0
    private let stateProvider: @MainActor () -> CaptureState
    private let handler: @MainActor (RecordingRemoteAction) async -> Void

    public init(
        sessionID: UUID,
        state: @escaping @MainActor () -> CaptureState,
        handler: @escaping @MainActor (RecordingRemoteAction) async -> Void
    ) {
        self.sessionID = sessionID
        self.stateProvider = state
        self.handler = handler
    }

    /// True while the capture is armed or recording — the only states in which a
    /// remote command is honored (§14.3).
    public var isActive: Bool {
        switch stateProvider() {
        case .prepared, .monitoring, .recording: return true
        case .idle, .stopping, .failed: return false
        }
    }

    /// Delivers one command. Returns the outcome so the phone can acknowledge
    /// and the watch can show "iPhone isn't recording" on `.dropped`.
    @discardableResult
    public func deliver(_ command: RecordingRemoteCommand) async -> RecordingRemoteOutcome {
        guard command.sessionID == sessionID else { return .foreignSession }
        guard command.sequence > lastSequence else { return .duplicate }
        guard isActive else { return .dropped }
        lastSequence = command.sequence
        await handler(command.action)
        return .accepted
    }

    /// The highest sequence this coordinator has dispatched. A dropped command
    /// does not advance it, so a retry of the same command is honored once the
    /// capture becomes active again.
    public var dispatchedSequence: Int { lastSequence }
}
