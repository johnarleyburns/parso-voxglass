import Foundation
import Observation
import VoxglassCore

/// The watch recording-remote model (mockup watch-04, §14.3). Observes the live
/// session telemetry the iPhone relays and sends idempotent `RecordingRemoteCommand`s
/// back over the same link. The watch never records audio — it only sends commands.
@MainActor
@Observable
public final class WatchRecordingRemoteModel {

    public private(set) var status: RecordingRemoteStatus?
    public private(set) var error: String?
    public private(set) var lastCommand: RecordingRemoteAction?

    private let environment: ProductionWatchEnvironment
    private var sequenceBySession: [UUID: Int] = [:]

    public init(environment: ProductionWatchEnvironment) {
        self.environment = environment
    }

    /// Consumes the status stream for the lifetime of the remote screen.
    public func start() async {
        for await status in environment.transport.receiveRecordingRemoteStatus() {
            self.status = status
            self.error = nil
        }
    }

    /// Sends one command, targeted at the session the phone is currently
    /// relaying, with a monotonic per-session sequence so a retry of the same
    /// tap can never produce a second take (§14.3).
    public func send(_ action: RecordingRemoteAction) async {
        guard let sessionID = status?.sessionID else {
            error = "iPhone isn't recording."
            return
        }
        let sequence = (sequenceBySession[sessionID] ?? 0) + 1
        sequenceBySession[sessionID] = sequence
        let command = RecordingRemoteCommand(sessionID: sessionID, sequence: sequence, action: action)
        lastCommand = action
        do {
            try await environment.transport.sendRecordingRemoteCommand(command)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Whether the watch already holds a review proxy for the paragraph being
    /// recorded, so "play take" can work with a previously transferred file —
    /// no audio crosses the link live.
    public func canPlayTake() -> Bool {
        guard let paragraphID = status?.paragraphID else { return false }
        return environment.audioStore.hasAudio(for: paragraphID)
    }

    /// Plays the previously-transferred review proxy of the paragraph being
    /// recorded, if the watch has one.
    public func playTake() {
        guard let paragraphID = status?.paragraphID,
              let url = environment.audioStore.localURL(for: paragraphID) else { return }
        environment.player.load(url: url, paragraphID: paragraphID)
        environment.player.play()
    }

    /// True when the phone reports a session that is armed or recording.
    public var hasLiveSession: Bool {
        status?.isArmed == true
    }
}
