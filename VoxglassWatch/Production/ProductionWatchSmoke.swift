import Foundation
import VoxglassCore
import Observation

/// Launch-arg/env detection for the watch UI smoke seed (`-uiTestSeed watchQueue`,
/// or `VOXGLASS_WATCH_SMOKE_PRODUCTION=1`). Mirrors the existing watch's
/// `VOXGLASS_WATCH_SMOKE_ALICE` convention.
public enum ProductionWatchSmoke {

    public static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment["VOXGLASS_WATCH_SMOKE_PRODUCTION"] == "1"
        let args = ProcessInfo.processInfo.arguments
        let flag = args.contains("-VOXGLASS_WATCH_SMOKE_PRODUCTION")
        let seed = args.firstIndex(of: "-uiTestSeed").map { index in
            args.indices.contains(index + 1) ? args[index + 1] : nil
        } ?? nil
        return environment || flag || seed == "watchQueue"
    }

    @MainActor
    public static func makeTransport() -> any WatchTransport {
        SmokeWatchTransport()
    }

    /// Deterministic in-app fake: preloaded with the `watchQueue` fixture, records
    /// review events so the offline outbox flush completes without a phone.
    @MainActor
    @Observable
    public final class SmokeWatchTransport: @preconcurrency WatchTransport {
        public let seedSummaries: [ProjectSummary]
        public let seedQueue: ResolvedQueuePayload
        public let seedAudio: [WatchAudioItem]

        public var isReachable = true
        public var activationState: WatchLinkState = .reachable
        public private(set) var recordedEvents: [ReviewEvent] = []

        public init(seed: (summaries: [ProjectSummary], queue: ResolvedQueuePayload, audio: [WatchAudioItem]) = ProductionWatchFixtures.watchQueueSeed()) {
            self.seedSummaries = seed.summaries
            self.seedQueue = seed.queue
            self.seedAudio = seed.audio
            var statusContinuation: AsyncStream<RecordingRemoteStatus>.Continuation!
            statusStream = AsyncStream { statusContinuation = $0 }
            self.statusContinuation = statusContinuation
        }

        public func sendSummaries(_ summaries: [ProjectSummary]) async throws {}
        public func sendActiveQueue(_ payload: ResolvedQueuePayload) async throws {}
        public func sendAudio(_ items: [WatchAudioItem]) async throws {}
        public func sendArtwork(_ artwork: [UUID: Data]) async throws {}
        public func sendEvents(_ events: [ReviewEvent]) async throws {
            recordedEvents.append(contentsOf: events)
        }
        public func receiveEvents() -> AsyncStream<ReviewEvent> {
            AsyncStream { _ in }
        }
        public func requestRefresh() async throws {}

        public func sendRecordingRemoteCommand(_ command: RecordingRemoteCommand) async throws {
            sentRecordingCommands.append(command)
        }
        public func sendRecordingRemoteStatus(_ status: RecordingRemoteStatus) async throws {
            lastRecordingStatus = status
            statusContinuation.yield(status)
        }
        public func receiveRecordingRemoteStatus() -> AsyncStream<RecordingRemoteStatus> {
            statusStream
        }

        public private(set) var sentRecordingCommands: [RecordingRemoteCommand] = []
        public private(set) var lastRecordingStatus: RecordingRemoteStatus?
        private let statusContinuation: AsyncStream<RecordingRemoteStatus>.Continuation
        public let statusStream: AsyncStream<RecordingRemoteStatus>
    }
}
