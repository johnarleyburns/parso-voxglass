import Foundation

/// The data seams the CarPlay production surface depends on. The phone-side
/// concrete implementations arrive with S5 (CloudKit projection preview); tests
/// use fakes. Keeping them in Core means the whole production CarPlay logic —
/// including the controller's behavior in the absence of data — stays
/// host-testable.
public protocol CarPlayProductionDataProviding: Sendable {
    /// The production summaries currently projected to the phone. Synchronous:
    /// the phone's projection preview store is a local cache (S5).
    func productionSummaries() -> [ProjectSummary]

    /// The resolved review queue for the given type, or nil when none is available.
    func queuePayload(_ type: ProductionQueueType) -> ResolvedQueuePayload?
}

/// Delivers review events to the phone's outbox. Synchronous because the phone
/// outbox is in-process (file-backed); the async flush to CloudKit is the sync
/// engine's job (S5).
public protocol CarPlayEventDelivering: Sendable {
    func send(_ events: [ReviewEvent]) throws
}

/// Plays one paragraph's audio for the now-playing template. The concrete proxy
/// player lands with S5 (projection proxies); tests use a fake.
public protocol CarPlayProductionPlaying: Sendable {
    func play(paragraphID: UUID, in payload: ResolvedQueuePayload) async
    func pause() async
}

/// The three review confirmations, each with a bundled pre-recorded earcon
/// (spec §18.3 rule 6: audio confirmations are tones, never speech synthesis).
public enum CarPlayCueKind: String, Sendable, CaseIterable {
    case approve
    case flag
    case pickup
}

/// Plays a short confirmation earcon after a review action. Implemented by
/// `BundledCarPlayCuePlayer` in the app target (AVAudioPlayer over the bundled
/// tones); tests use a recording fake.
public protocol CarPlayCuePlaying: Sendable {
    func play(_ cue: CarPlayCueKind)
}

/// A no-op cue player for test environments where audio must not be produced.
public struct SilentCarPlayCuePlayer: CarPlayCuePlaying {
    public init() {}
    public func play(_ cue: CarPlayCueKind) {}
}

/// The consumer tab sections shown in the production tab bar's "Continue" tab.
public typealias CarPlayContinueProvider = @MainActor () -> [CarPlaySection]
