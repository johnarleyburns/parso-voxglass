import Foundation
import Testing
@testable import VoxglassCore

/// §16.2 `RecordingRemoteTests` — the recording-remote command path (spec §14.3).
///
/// The phone-side gate is `RecordingRemoteCoordinator`: commands are idempotent
/// by `(sessionID, sequence)` and only honored while the capture is armed or
/// recording. A duplicated `transferUserInfo` MUST NOT produce a second take;
/// a command that arrives while idle is acknowledged and dropped.
@MainActor
@Suite struct RecordingRemoteTests {

    /// A fake capture whose state the test controls, so the gate's behavior can
    /// be asserted without any audio hardware.
    private final class FakeState {
        var state: CaptureState = .idle
    }

    /// A fake action executor that records how many times each action was
    /// dispatched — "one take" means `stop`/`accept`/`retake` ran once.
    private final class FakeExecutor: @unchecked Sendable {
        var invocations: [RecordingRemoteAction] = []
        var takeCount = 0

        func handle(_ action: RecordingRemoteAction) async {
            invocations.append(action)
            if action == .stop || action == .accept || action == .retake {
                takeCount += 1
            }
        }
    }

    private struct Harness {
        let sessionID: UUID
        let state: FakeState
        let executor: FakeExecutor
        let coordinator: RecordingRemoteCoordinator

        @MainActor
        init(sessionID: UUID = UUID()) {
            let state = FakeState()
            let executor = FakeExecutor()
            let coordinator = RecordingRemoteCoordinator(
                sessionID: sessionID,
                state: { state.state },
                handler: { action in
                    await executor.handle(action)
                }
            )
            self.sessionID = sessionID
            self.state = state
            self.executor = executor
            self.coordinator = coordinator
        }

        func command(_ sequence: Int, _ action: RecordingRemoteAction) -> RecordingRemoteCommand {
            RecordingRemoteCommand(sessionID: sessionID, sequence: sequence, action: action)
        }
    }

    @Test
    func replayingTheSameCommandTwice_createsExactlyOneTake() async {
        let harness = Harness()
        harness.state.state = .recording

        let stop = harness.command(7, .stop)

        // Same (sessionID, sequence) delivered twice — a duplicated transfer.
        let first = await harness.coordinator.deliver(stop)
        let second = await harness.coordinator.deliver(stop)

        #expect(first == .accepted)
        #expect(second == .duplicate)
        #expect(harness.executor.takeCount == 1, "a duplicate transfer must not produce a second take")
        #expect(harness.executor.invocations.count == 1)
    }

    @Test
    func commandWhileIdle_producesNoStateChange() async {
        let harness = Harness()
        harness.state.state = .idle

        let outcome = await harness.coordinator.deliver(harness.command(1, .record))

        #expect(outcome == .dropped)
        #expect(harness.executor.invocations.isEmpty, "an idle command must not touch capture or review state")
        #expect(harness.coordinator.dispatchedSequence == 0, "a dropped command must not advance the sequence")
    }

    @Test
    func commandWhileStoppingOrFailed_isDropped() async {
        let harness = Harness()
        harness.state.state = .stopping

        let stopping = await harness.coordinator.deliver(harness.command(2, .record))
        #expect(stopping == .dropped)

        harness.state.state = .failed("no input")
        let failed = await harness.coordinator.deliver(harness.command(3, .record))
        #expect(failed == .dropped)

        #expect(harness.executor.invocations.isEmpty)
    }

    @Test
    func commandWhileArmedOrMonitoring_isHonored() async {
        let harness = Harness()
        harness.state.state = .prepared

        let prepared = await harness.coordinator.deliver(harness.command(1, .record))
        #expect(prepared == .accepted)

        harness.state.state = .monitoring
        let monitoring = await harness.coordinator.deliver(harness.command(2, .retake))
        #expect(monitoring == .accepted)

        #expect(harness.executor.invocations == [.record, .retake])
    }

    @Test
    func commandForAnotherSession_isDroppedAsForeign() async {
        let harness = Harness()
        harness.state.state = .recording

        let foreign = RecordingRemoteCommand(sessionID: UUID(), sequence: 1, action: .record)
        let outcome = await harness.coordinator.deliver(foreign)

        #expect(outcome == .foreignSession)
        #expect(harness.executor.invocations.isEmpty)
    }

    @Test
    func retryOfDroppedCommand_isHonoredOnceActive() async {
        let harness = Harness()
        harness.state.state = .idle

        // Delivered while idle → dropped, sequence NOT advanced.
        let dropped = await harness.coordinator.deliver(harness.command(5, .record))
        #expect(dropped == .dropped)
        #expect(harness.coordinator.dispatchedSequence == 0)

        // The phone becomes armed; the same command arrives again → honored.
        harness.state.state = .prepared
        let retried = await harness.coordinator.deliver(harness.command(5, .record))
        #expect(retried == .accepted)
        #expect(harness.executor.invocations == [.record])
    }

    @Test
    func commandRoundTripsThroughCodec() throws {
        let command = RecordingRemoteCommand(
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!,
            sequence: 3,
            action: .accept
        )
        let message = try WatchPhoneMessageCodec.message(
            action: ProductionTransportAction.recordingRemoteCommand,
            payload: command
        )
        let decoded = try WatchPhoneMessageCodec.payload(RecordingRemoteCommand.self, from: message)

        #expect(decoded == command)
        #expect(WatchPhoneMessageCodec.action(from: message) == ProductionTransportAction.recordingRemoteCommand)
    }

    @Test
    func statusRoundTripsThroughCodec() throws {
        let status = RecordingRemoteStatus(
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!,
            paragraphID: UUID(uuidString: "00000000-0000-4000-8000-00000000000C"),
            paragraphNumber: 1205,
            chapterTitle: "Chapter 3",
            elapsedSeconds: 7,
            levelDBFS: -21.5,
            isRecording: true,
            isArmed: true
        )
        let message = try WatchPhoneMessageCodec.message(
            action: ProductionTransportAction.recordingRemoteStatus,
            payload: status
        )
        let decoded = try WatchPhoneMessageCodec.payload(RecordingRemoteStatus.self, from: message)

        #expect(decoded == status)
    }
}
